require "peasant_road"
require "tmpdir"

RSpec.describe PeasantRoad::Library do
  let(:tmpdir) { Dir.mktmpdir }
  let(:repo) { PeasantRoad::DiskRepository.new(tmpdir) }
  let(:library) { described_class.new(repo: repo) }
  let(:mock_rr) { instance_double(PeasantRoad::RoyalRoadClient) }
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
    allow(PeasantRoad::RoyalRoadClient).to receive(:new).and_return(mock_rr)
    allow(mock_rr).to receive(:fic_info).and_return(fic_info)
  end

  after { FileUtils.rm_rf(tmpdir) }

  describe "#follow" do
    it "rejects non-RoyalRoad URLs" do
      expect { library.follow("https://example.com/fiction/1/") }.to raise_error(PeasantRoad::Library::InvalidURL)
    end

    it "registers a new story and persists its info" do
      result = library.follow(url)

      expect(result[:followed]).to be true
      expect(result[:fic_id]).to eq fic_id
      expect(library.config.followed_stories).to include(fic_id)
      expect(repo.read_fic_info(fic_id)["title"]).to eq "Sky Pride"
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
      changed = instance_double(PeasantRoad::Fic, fic_id: "1")
      unchanged = instance_double(PeasantRoad::Fic, fic_id: "2")
      changed_book = instance_double(PeasantRoad::Epub)
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
