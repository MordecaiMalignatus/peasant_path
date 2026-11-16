require "peasant_path"
require "peasant_path/browser"
require "tmpdir"

RSpec.describe PeasantPath::Library do
  let(:tmpdir) { Dir.mktmpdir }
  let(:repo) { PeasantPath::DiskRepository.new(tmpdir) }
  let(:mock_rr) { instance_double(PeasantPath::RoyalRoadClient) }
  # Stands in for RoyalRoadSession: yields a transport token without a browser.
  let(:rr_session) { Class.new { def open = yield(:transport) }.new }
  let(:library) { described_class.new(repo: repo, royalroad_session: rr_session, royalroad_client_for: ->(_transport) { mock_rr }) }
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

    it "keeps a rename made while the pull runs, and rebuilds under it" do
      renamed = false
      allow(mock_rr).to receive(:enrich_overview_chapter!) do |chapter|
        library.rename(fic_id, "Renamed") unless renamed
        renamed = true
        chapter.chapter_text = "<p>text</p>"
        chapter.chapter_title = "Title #{chapter.chapter_id}"
        chapter
      end

      library.refresh

      expect(repo.read_fic_info(fic_id)["display_name"]).to eq "Renamed"
      expect(File).to exist(repo.epub_path(fic_id, "Renamed.epub"))
    end

    it "appends a pull-log entry" do
      library.pull_all
      log = repo.read_pull_log

      expect(log.size).to eq 1
      expect(log.first["fics"].first["new_chapters"]).to contain_exactly("Title 2113501", "Title 2113560")
    end

    it "updates stats after chapter persistence" do
      library.pull_all
      info = repo.read_fic_info(fic_id)

      expect(repo.read_chapter(fic_id, "2113501")["word_count_estimate"]).to eq 1
      expect(info["stats"]).to include("word_count_estimate" => 2, "chapter_count" => 2)
      expect(info["volumes"].first).to include(
        "word_count_estimate" => 2,
        "chapter_count" => 2,
        "chapter_ids" => ["2113501", "2113560"],
      )
    end

    it "reports progress as each chapter is saved, before the pull finishes" do
      events = []
      results = library.pull_all do |event, fic, detail|
        events << [event, fic.fic_id, event == :chapter ? detail.chapter_id : detail]
        expect(repo.chapter_exists?(fic_id, detail.chapter_id)).to be true if event == :chapter
      end

      expect(events).to eq [
        [:started, fic_id, nil],
        [:chapter, fic_id, "2113501"],
        [:chapter, fic_id, "2113560"],
        [:finished, fic_id, results.first],
      ]
    end

    it "re-raises a failing progress block instead of recording it as the fic's error" do
      expect { library.pull_all { |event, *| raise Errno::EPIPE if event == :finished } }.to raise_error(Errno::EPIPE)

      log = repo.read_pull_log
      expect(log.size).to eq 1
      expect(log.first["fics"].map { |f| [f["fic_id"], f["error"]] }).to eq [[fic_id, nil]]
    end

    it "captures per-fic errors instead of raising" do
      allow(mock_rr).to receive(:chapter_overview).and_raise("network down")
      results = library.pull_all

      expect(results.first[:error]).to eq "network down"
      expect(results.first[:new_chapters]).to be_empty
    end

    context "when the browser cannot be launched" do
      let(:rr_session) do
        Class.new { def open = raise(PeasantPath::Browser::NotInstalled, "playwright-core not found") }.new
      end

      it "reports the fic as finished with the error without having started it" do
        events = []
        library.pull_all { |event, _fic, detail| events << [event, detail && detail[:error]] }

        expect(events).to eq [[:finished, "playwright-core not found"]]
      end

      it "records the error against the RoyalRoad fic instead of raising" do
        results = library.pull_all

        expect(results.first[:error]).to eq "playwright-core not found"
        expect(repo.read_pull_log.last["fics"].first["error"]).to eq "playwright-core not found"
      end
    end
  end

  # Ahead of a book release, Royal Road authors "stub" a story: they take
  # its first chapters off the site, often leaving a teaser chapter pointing
  # at the book where they were, while new chapters keep coming. Royal Road
  # then renumbers its chapter list from the first chapter still up. The
  # chapters already pulled are the reader's copy and must stay in the
  # EPUBs, in their places.
  describe "when the author stubs the start of the story" do
    let(:fic_info) do
      {
        description: "A story.", title: "Sky Pride", author: "Author", cover_image: "fake_cover",
        volumes: [{ "id" => 1, "title" => "Book 1", "cover" => "x" }, { "id" => 2, "title" => "Book 2", "cover" => "x" }],
        volume_covers: { 1 => "fake_vol_cover", 2 => "fake_vol_cover" },
      }
    end

    # Chapter ids grow as chapters are created; order is the position in the
    # list Royal Road serves at the time.
    def toc_entry(id, order, volume_id)
      { "id" => id, "volumeId" => volume_id, "order" => order, "title" => "Chapter #{id}",
        "url" => "/fiction/107917/sky-pride/chapter/#{id}/chapter-#{id}" }
    end

    def epub_titles(filename)
      Zip::File.open(repo.epub_path(fic_id, filename)) do |zip|
        zip.entries
          .filter_map { |entry| [Regexp.last_match(1).to_i, entry] if entry.name =~ %r{text/chapter-(\d+)\.xhtml\z} }
          .sort_by(&:first)
          .map { |_, entry| entry.get_input_stream.read[%r{<title>(.*?)</title>}, 1] }
      end
    end

    # 100 chapters, 50 per book.
    let(:original_toc) { (0...100).map { |i| toc_entry(5000 + i, i, i < 50 ? 1 : 2) } }
    # Chapters 1-80 gone, a teaser (created at stub time) in their place,
    # chapters 81-100 renumbered from 1, and two new chapters after them.
    let(:stubbed_toc) do
      [toc_entry(5150, 0, nil)] +
        original_toc.drop(80).each_with_index.map { |entry, i| entry.merge("order" => i + 1) } +
        [toc_entry(5200, 21, 2), toc_entry(5201, 22, 2)]
    end
    let(:fetched) { [] }

    before do
      allow(mock_rr).to receive(:throttle=)
      allow(mock_rr).to receive(:enrich_overview_chapter!) do |chapter|
        fetched << chapter.chapter_id
        chapter.chapter_text = "<p>text of #{chapter.chapter_id}</p>"
        chapter.chapter_title = "Chapter #{chapter.chapter_id}"
        chapter
      end
      allow(mock_rr).to receive(:chapter_overview).with(fic_id).and_return(original_toc, stubbed_toc)
      library.follow(url)
    end

    it "keeps every stubbed chapter in the EPUB, in its place, with the new chapters after" do
      library.refresh
      before_stub = epub_titles("Sky Pride.epub")
      fetched.clear

      library.refresh
      library.rebuild_all
      after_stub = epub_titles("Sky Pride.epub")

      expect(fetched).to eq %w[5150 5200 5201]
      expect(after_stub.first(100)).to eq before_stub
      expect(after_stub.drop(100)).to eq ["Chapter 5200", "Chapter 5201"]
    end

    it "saves the teaser, but leaves it out of the EPUBs and says so" do
      log = StringIO.new
      library = described_class.new(repo: repo, logger: Logger.new(log), royalroad_session: rr_session, royalroad_client_for: ->(_transport) { mock_rr })

      library.refresh
      library.refresh

      expect(log.string).to include('Sky Pride: "Chapter 5150" looks like a stubbing teaser; saved, but left out of the EPUBs')
      expect(repo.chapter_exists?(fic_id, "5150")).to be true
      expect(PeasantPath::Fic.from_disk(fic_id, repo).chapters.find { |c| c.chapter_id == "5150" }).to be_teaser
      expect(epub_titles("Sky Pride.epub")).not_to include("Chapter 5150")
    end

    # A pull builds from the chapters it holds in memory; "Rebuild all", a
    # rename and the CLI's build read them back from disk. Following a story
    # that is already stubbed has Royal Road list the teaser ahead of older
    # chapters, so the two only agree if the pull sorts the same way. (With
    # nothing pulled yet, nothing marks the teaser as one, so it stays in.)
    it "builds the same book right after a pull as when rebuilding from disk" do
      allow(mock_rr).to receive(:chapter_overview).with(fic_id).and_return(stubbed_toc)

      library.refresh
      after_pull = epub_titles("Sky Pride.epub")
      library.rebuild_all

      expect(epub_titles("Sky Pride.epub")).to eq after_pull
      expect(after_pull).to eq((5080...5100).map { |id| "Chapter #{id}" } + ["Chapter 5150", "Chapter 5200", "Chapter 5201"])
    end

    it "keeps building the volume that was stubbed entirely" do
      library.refresh
      book_1 = epub_titles("Sky Pride - Book 1.epub")

      library.refresh
      library.rebuild_all

      expect(epub_titles("Sky Pride - Book 1.epub")).to eq book_1
      expect(book_1).to eq((5000...5050).map { |id| "Chapter #{id}" })
      expect(epub_titles("Sky Pride - Book 2.epub")).to eq((5050...5100).map { |id| "Chapter #{id}" } + ["Chapter 5200", "Chapter 5201"])
    end
  end

  describe "#rebuild_changed" do
    it "rebuilds only the fics that gained chapters, into the build directory" do
      changed = instance_double(PeasantPath::Fic, fic_id: "1", display_title: "Changed")
      unchanged = instance_double(PeasantPath::Fic, fic_id: "2")
      changed_book = instance_double(PeasantPath::Epub)
      allow(changed).to receive(:book).and_return(changed_book)
      allow(changed).to receive(:reload_display_name!).and_return(changed)
      allow(changed).to receive(:refresh_stats!)
      allow(changed_book).to receive(:build_all)
      allow(unchanged).to receive(:book)

      library.rebuild_changed([
        { fic: changed, new_chapters: [double("Chapter")], error: nil },
        { fic: unchanged, new_chapters: [], error: nil },
      ])

      expect(changed_book).to have_received(:build_all).with(repo.build_dir("1"))
      expect(changed).to have_received(:refresh_stats!)
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

RSpec.describe PeasantPath::Library, "with Patreon fics" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:repo) { PeasantPath::DiskRepository.new(tmpdir) }
  let(:mock_rr) { instance_double(PeasantPath::RoyalRoadClient) }
  let(:fake_patreon) { instance_double(PeasantPath::PatreonClient, verify_login!: true) }
  let(:session_error) { nil }
  let(:error_after_block) { nil }
  # Stands in for PatreonSession: yields a transport token, optionally failing
  # before the block (not installed) or after it (browser went away on close).
  let(:fake_session) do
    Class.new do
      attr_reader :opens

      def initialize(before, after)
        @before = before
        @after = after
        @opens = 0
      end

      def open(profile_dir:)
        @opens += 1
        raise @before if @before
        result = yield :transport
        raise @after if @after
        result
      end
    end.new(session_error, error_after_block)
  end
  let(:library) do
    described_class.new(
      repo: repo,
      royalroad_session: Class.new { def open = yield(:transport) }.new,
      royalroad_client_for: ->(_transport) { mock_rr },
      patreon_session: fake_session,
      patreon_profile_dir: File.join(tmpdir, "profile"),
      patreon_client_for: ->(_transport) { fake_patreon },
    )
  end
  let(:url) { "https://www.patreon.com/collection/1522125?view=expanded" }
  let(:fic_id) { "patreon-col-1522125" }

  after { FileUtils.rm_rf(tmpdir) }

  def patreon_chapter(fic, id, order)
    chapter = PeasantPath::Chapter.new("https://www.patreon.com/u84402213/posts/x-#{id}", fic_id: fic.fic_id, chapter_id: id, source: "patreon", repository: repo)
    chapter.chapter_title = "Chapter #{order}"
    chapter.chapter_text = "<div class=\"chapter-content\"><p>Words here.</p></div>"
    chapter.order_number = order
    chapter
  end

  def stub_successful_patreon_pull
    allow(fake_patreon).to receive(:throttle=)
    allow(fake_patreon).to receive(:fic_info).and_return(
      title: "Path of the Deathless", author: "OstensibleMammal", description: "", cover_image: "png",
      volumes: [], volume_covers: {}, source_ref: { "campaign_id" => "9755002" },
    )
    allow(fake_patreon).to receive(:chapter_overview) do |fic, known_ids:|
      [patreon_chapter(fic, "130012200", 0), patreon_chapter(fic, "130012322", 1)]
    end
    allow(fake_patreon).to receive(:enrich_overview_chapter!) { |chapter| chapter }
  end

  describe "#follow" do
    it "records the source, canonical uri and source_ref without touching the network" do
      result = library.follow(url)

      expect(result[:followed]).to be true
      expect(result[:fic_id]).to eq fic_id
      info = repo.read_fic_info(fic_id)
      expect(info).to include("source" => "patreon", "uri" => "https://www.patreon.com/collection/1522125", "source_ref" => { "collection_id" => "1522125" })
    end
  end

  describe "#pull_all" do
    before do
      library.follow(url)
      library.follow("https://www.royalroad.com/fiction/107917/sky-pride")
      allow(mock_rr).to receive(:throttle=)
      allow(mock_rr).to receive(:fic_info).and_return(title: "Sky Pride", author: "A", description: "", cover_image: "img", volumes: [], volume_covers: {})
      allow(mock_rr).to receive(:chapter_overview).with("107917").and_return([])
    end

    it "pulls Patreon fics through a client built on the session's transport and RoyalRoad fics through the RoyalRoad client" do
      stub_successful_patreon_pull
      allow(fake_patreon).to receive(:chapter_overview) do |fic, known_ids:|
        expect(known_ids).to eq []
        [patreon_chapter(fic, "130012200", 0), patreon_chapter(fic, "130012322", 1)]
      end

      results = library.pull_all
      by_id = results.to_h { |r| [r[:fic].fic_id, r] }

      expect(fake_session.opens).to eq 1
      expect(fake_patreon).to have_received(:verify_login!).once
      expect(by_id[fic_id][:error]).to be_nil
      expect(by_id[fic_id][:new_chapters].map(&:chapter_id)).to eq %w[130012200 130012322]
      expect(by_id["107917"][:new_chapters]).to be_empty
      info = repo.read_fic_info(fic_id)
      expect(info["source_ref"]).to eq("collection_id" => "1522125", "campaign_id" => "9755002")
      expect(info["stats"]["chapter_count"]).to eq 2
      expect(repo.read_chapter(fic_id, "130012200")).to include("source" => "patreon", "chapter_id" => "130012200")
    end

    it "reports each fic exactly once, grouped by source in follow order" do
      stub_successful_patreon_pull

      results = library.pull_all

      expect(results.map { |r| r[:fic].fic_id }).to eq [fic_id, "107917"]
      expect(repo.read_pull_log.last["fics"].map { |f| f["fic_id"] }).to eq [fic_id, "107917"]
    end

    it "passes the ids already on disk so the client can stop paginating early" do
      repo.write_chapter_hash(fic_id, "130012200", { fic_id: fic_id, chapter_id: "130012200", source: "patreon", chapter_uri: "https://www.patreon.com/u84402213/posts/x-130012200", chapter_title: "Chapter 0", chapter_text: "<p>x</p>", order_number: 0 })
      allow(fake_patreon).to receive(:throttle=)
      allow(fake_patreon).to receive(:fic_info).and_return(title: "T", author: "A", description: "", cover_image: "png", volumes: [], volume_covers: {})
      allow(fake_patreon).to receive(:chapter_overview).with(anything, known_ids: ["130012200"]).and_return([])

      results = library.pull_all
      patreon_result = results.find { |r| r[:fic].fic_id == fic_id }

      expect(patreon_result[:error]).to be_nil
      expect(patreon_result[:new_chapters]).to be_empty
    end

    context "when the browser session cannot be opened" do
      let(:session_error) do
        require "peasant_path/patreon_session"
        PeasantPath::PatreonSession::NotInstalled.new("playwright-core not found. Patreon support needs Node")
      end

      it "records the error against every Patreon fic without aborting the RoyalRoad pulls" do
        results = library.pull_all
        by_id = results.to_h { |r| [r[:fic].fic_id, r] }

        expect(by_id["107917"][:error]).to be_nil
        expect(by_id[fic_id][:error]).to match(/playwright-core not found/)
        expect(repo.read_pull_log.last["fics"].find { |f| f["fic_id"] == fic_id }["error"]).to match(/playwright-core not found/)
        expect(fake_patreon).not_to have_received(:verify_login!)
      end
    end

    context "when the saved session has expired" do
      before do
        allow(fake_patreon).to receive(:verify_login!).and_raise(PeasantPath::PatreonClient::AuthRequired, "Patreon session is not logged in (HTTP 401); run 'peasant_path patreon login'")
        allow(fake_patreon).to receive(:fic_info)
      end

      it "turns the expired login into a per-fic error instead of a silent empty pull" do
        results = library.pull_all
        by_id = results.to_h { |r| [r[:fic].fic_id, r] }

        expect(by_id[fic_id][:error]).to match(/patreon login/)
        expect(by_id["107917"][:error]).to be_nil
        expect(fake_patreon).not_to have_received(:fic_info)
        expect(repo.read_pull_log.last["fics"].find { |f| f["fic_id"] == fic_id }["error"]).to match(/not logged in/)
      end
    end

    context "when the session fails after the fics were pulled" do
      let(:error_after_block) { RuntimeError.new("Target closed") }

      it "keeps the successful entries and does not record the fics a second time" do
        stub_successful_patreon_pull

        results = library.pull_all

        expect(results.map { |r| r[:fic].fic_id }).to eq [fic_id, "107917"]
        patreon_result = results.find { |r| r[:fic].fic_id == fic_id }
        expect(patreon_result[:error]).to be_nil
        expect(patreon_result[:new_chapters].size).to eq 2
        log_ids = repo.read_pull_log.last["fics"].map { |f| f["fic_id"] }
        expect(log_ids.count(fic_id)).to eq 1
      end
    end
  end

  describe "#pull_fic" do
    it "opens a session for a single Patreon fic" do
      stub_successful_patreon_pull
      fic = library.follow(url)[:fic]

      new_chapters = library.pull_fic(fic)

      expect(new_chapters.size).to eq 2
      expect(fake_session.opens).to eq 1
    end
  end
end
