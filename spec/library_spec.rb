require "peasant_path"
require "tmpdir"

RSpec.describe PeasantPath::Library do
  let(:tmpdir) { Dir.mktmpdir }
  let(:repo) { PeasantPath::DiskRepository.new(tmpdir) }
  let(:mock_rr) { instance_double(PeasantPath::RoyalRoadClient) }
  let(:library) { described_class.new(repo: repo, client: mock_rr) }
  let(:fic_id) { "107917" }
  let(:url) { "https://www.royalroad.com/fiction/107917/sky-pride" }

  let(:fic_info) do
    {
      description: "A story.",
      title: "Sky Pride",
      author: "Author",
      cover_image: "fake_cover",
      volumes: [{ "id" => 10395, "title" => "Volume 1", "cover" => "x" }],
      volume_covers: { 10395 => "fake_vol_cover" },
    }
  end

  let(:overview) do
    [
      { "id" => 2113501, "volumeId" => 10395, "order" => 0, "title" => "Chapter 1", "url" => "/fiction/107917/sky-pride/chapter/2113501/chapter-1" },
      { "id" => 2113560, "volumeId" => 10395, "order" => 1, "title" => "Chapter 2", "url" => "/fiction/107917/sky-pride/chapter/2113560/chapter-2" },
    ]
  end

  before do
    allow(mock_rr).to receive(:fic_info).and_return(fic_info)
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe "#follow" do
    it "rejects non-RoyalRoad URLs" do
      expect { library.follow("https://example.com/fiction/1/") }.to raise_error(PeasantPath::Library::InvalidURL)
    end

    it "raises InvalidURL (not URI::InvalidURIError) for a malformed URL" do
      expect { library.follow("http://[bad") }.to raise_error(PeasantPath::Library::InvalidURL)
    end

    it "raises InvalidURL for a RoyalRoad URL with no fiction path" do
      expect { library.follow("https://www.royalroad.com/") }.to raise_error(PeasantPath::Library::InvalidURL)
    end

    it "registers a new story with a minimal record and no network" do
      expect(mock_rr).not_to receive(:fic_info)
      result = library.follow(url)

      expect(result[:followed]).to be true
      expect(result[:fic_id]).to eq fic_id
      expect(library.config.followed_stories).to include(fic_id)
      # The metadata is fetched later by the background pull, so the record
      # exists but the scraped title isn't populated yet.
      expect(repo.read_fic_info(fic_id)).to have_key("title")
      expect(repo.read_fic_info(fic_id)["title"]).to be_nil
    end

    it "passes the display name through" do
      result = library.follow(url, name: "My Name")
      expect(result[:fic].display_title).to eq "My Name"
    end

    it "is idempotent for an already-followed story" do
      library.follow(url)
      result = library.follow(url)

      expect(result[:followed]).to be false
      expect(library.config.followed_stories.count(fic_id)).to eq 1
    end
  end

  describe "#pull_all" do
    before do
      allow(mock_rr).to receive(:throttle=)
      allow(mock_rr).to receive(:chapter_overview).with(fic_id).and_return(overview)
      allow(mock_rr).to receive(:enrich_overview_chapter!) do |chapter|
        chapter.chapter_text = "<p>text</p>"
        chapter.chapter_title = "Title #{chapter.chapter_id}"
        chapter
      end
      library.follow(url)
    end

    it "returns per-fic results with the newly pulled chapters" do
      results = library.pull_all

      expect(results.size).to eq 1
      expect(results.first[:error]).to be_nil
      expect(results.first[:new_chapters].map(&:chapter_id)).to contain_exactly("2113501", "2113560")
    end

    it "appends a pull-log entry" do
      library.pull_all
      log = repo.read_pull_log

      expect(log.size).to eq 1
      expect(log.first["fics"].first["new_chapters"]).to contain_exactly("Title 2113501", "Title 2113560")
    end

    it "captures per-fic errors instead of raising" do
      allow(mock_rr).to receive(:chapter_overview).and_raise("network down")
      results = library.pull_all

      expect(results.first[:error]).to eq "network down"
      expect(results.first[:new_chapters]).to be_empty
    end
  end

  describe "#rebuild_changed" do
    it "rebuilds only the fics that gained chapters, into the build directory" do
      changed = instance_double(PeasantPath::Fic, fic_id: "1", display_title: "Changed")
      unchanged = instance_double(PeasantPath::Fic, fic_id: "2")
      changed_book = instance_double(PeasantPath::Epub)
      allow(changed).to receive(:book).and_return(changed_book)
      allow(changed_book).to receive(:build_all)
      allow(unchanged).to receive(:book)

      library.rebuild_changed([
        { fic: changed, new_chapters: [double("Chapter")], error: nil },
        { fic: unchanged, new_chapters: [], error: nil },
      ])

      expect(changed_book).to have_received(:build_all).with(repo.build_dir("1"))
      expect(unchanged).not_to have_received(:book)
    end
  end

  describe "#rename" do
    # follow no longer fetches metadata, so simulate the post-pull state where
    # the scraped title and volumes are already persisted on disk.
    before do
      library.follow(url)
      info = repo.read_fic_info(fic_id)
      info["title"] = "Sky Pride"
      info["volumes"] = [{ "id" => 10395, "title" => "Volume 1" }]
      repo.write_fic_info(fic_id, JSON.pretty_generate(info))
    end

    it "sets the display name while preserving the scraped info" do
      fic = library.rename(fic_id, "New Title")

      expect(fic.display_title).to eq "New Title"
      info = repo.read_fic_info(fic_id)
      expect(info["display_name"]).to eq "New Title"
      expect(info["title"]).to eq "Sky Pride"
    end

    it "clears a blank name back to the scraped title" do
      library.rename(fic_id, "New Title")
      fic = library.rename(fic_id, "  ")

      expect(fic.display_title).to eq "Sky Pride"
      expect(repo.read_fic_info(fic_id)["display_name"]).to be_nil
    end

    it "renames the existing builds so downloads stay available" do
      FileUtils.mkdir_p(repo.build_dir(fic_id))
      File.write(repo.epub_path(fic_id, "Sky Pride.epub"), "epub")
      File.write(repo.epub_path(fic_id, "Sky Pride - Volume 1.epub"), "vol")

      library.rename(fic_id, "New Title")

      expect(File).to exist(repo.epub_path(fic_id, "New Title.epub"))
      expect(File).to exist(repo.epub_path(fic_id, "New Title - Volume 1.epub"))
      expect(File).not_to exist(repo.epub_path(fic_id, "Sky Pride.epub"))
    end
  end

  describe "#unfollow" do
    it "removes the fic from config without deleting files" do
      library.follow(url)
      repo.write_chapter_hash(fic_id, "2113501", {
        fic_id: fic_id,
        chapter_uri: "https://www.royalroad.com/fiction/107917/sky-pride/chapter/2113501/chapter-1",
        chapter_title: "Chapter 1",
        chapter_text: "<p>text</p>",
      })

      expect(library.unfollow(fic_id)).to be true

      expect(library.config.followed_stories).to be_empty
      expect(repo.chapter_exists?(fic_id, "2113501")).to be true
    end

    it "returns false for a fic that was not followed" do
      expect(library.unfollow(fic_id)).to be false
    end
  end

  describe "#report" do
    it "returns active and quiet report rows" do
      library.follow(url)
      repo.append_pull_log(
        timestamp: Time.now.iso8601,
        fics: [{ fic_id: fic_id, title: "Sky Pride", new_chapters: ["Chapter 1"] }],
      )

      report = library.report(hours: 1)

      expect(report[:active].first.last[:title]).to eq "Sky Pride"
      expect(report[:quiet]).to be_empty
    end
  end

  describe "#pull_status_by_fic" do
    it "returns the latest pull status for each fic" do
      repo.append_pull_log(timestamp: (Time.now - 60).iso8601, fics: [{ fic_id: fic_id, title: "Sky Pride", new_chapters: [] }])
      repo.append_pull_log(timestamp: Time.now.iso8601, fics: [{ fic_id: fic_id, title: "Sky Pride", new_chapters: ["Chapter 1"], error: "boom" }])

      status = library.pull_status_by_fic[fic_id]

      expect(status[:new_chapter_count]).to eq 1
      expect(status[:error]).to eq "boom"
    end
  end

  describe "#refresh" do
    before do
      allow(mock_rr).to receive(:throttle=)
      allow(mock_rr).to receive(:chapter_overview).with(fic_id).and_return(overview)
      allow(mock_rr).to receive(:enrich_overview_chapter!) do |chapter|
        chapter.chapter_text = "<p>text</p>"
        chapter.chapter_title = "Title #{chapter.chapter_id}"
        chapter
      end
      library.follow(url)
    end

    it "pulls and then rebuilds the fic that changed" do
      allow(library).to receive(:rebuild)
      library.refresh
      expect(library).to have_received(:rebuild).once
    end
  end
end
