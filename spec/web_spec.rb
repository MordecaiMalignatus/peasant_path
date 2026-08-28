require "peasant_path"
require "peasant_path/web"
require "rack/test"
require "tmpdir"
require "json"

RSpec.describe PeasantPath::Web do
  include Rack::Test::Methods

  def app
    PeasantPath::Web
  end

  let(:tmpdir) { Dir.mktmpdir }
  let(:repo) { PeasantPath::DiskRepository.new(tmpdir) }
  let(:mock_rr) { instance_double(PeasantPath::RoyalRoadClient) }
  let(:library) { PeasantPath::Library.new(repo: repo, clients: { "royalroad" => mock_rr }) }
  let(:fic_id) { "107917" }

  # Records that a background job was requested without spawning a thread or
  # touching the network, so route behaviour can be asserted deterministically.
  let(:jobs) do
    Class.new do
      attr_reader :runs

      def initialize = @runs = 0
      def busy? = false
      def run = (@runs += 1) && true
    end.new
  end

  # Web is a Sinatra class with class-level settings, so injecting test doubles
  # mutates global state. Capture the prior values and restore them afterwards so
  # nothing leaks between examples or into other specs loaded later.
  before do
    @prior_settings = {
      library: PeasantPath::Web.settings.library,
      jobs: PeasantPath::Web.settings.jobs,
      app_logger: PeasantPath::Web.settings.app_logger,
    }
    PeasantPath::Web.set(:library, library)
    PeasantPath::Web.set(:jobs, jobs)
    PeasantPath::Web.set(:app_logger, Logger.new(File::NULL))
  end

  after do
    @prior_settings.each { |key, value| PeasantPath::Web.set(key, value) }
    FileUtils.rm_rf(tmpdir)
  end

  def follow_fic(title: "Sky Pride", volumes: [], stats: nil)
    repo.write_config_file(JSON.generate(followed_stories: [fic_id]))
    info = { title: title, author: "Author", volumes: volumes }
    info[:stats] = stats if stats
    repo.write_fic_info(fic_id, JSON.generate(info))
  end

  def write_chapter(chapter_id, text)
    repo.write_chapter_hash(fic_id, chapter_id, {
      fic_id: fic_id,
      chapter_uri: "https://www.royalroad.com/fiction/#{fic_id}/sky-pride/chapter/#{chapter_id}/chapter",
      chapter_title: "Chapter #{chapter_id}",
      chapter_text: text,
    })
  end

  describe "GET /" do
    it "renders the add form when nothing is followed" do
      get "/"
      expect(last_response).to be_ok
      expect(last_response.body).to include("No stories followed yet")
    end

    it "lists a followed story" do
      follow_fic
      get "/"
      expect(last_response.body).to include("Sky Pride")
    end

    it "escapes dynamic story output" do
      follow_fic(title: "Sky <script>alert(1)</script>", volumes: [{ "id" => 10395, "title" => "Vol <b>1</b>" }])
      FileUtils.mkdir_p(repo.build_dir(fic_id))
      File.write(repo.epub_path(fic_id, repo.epub_filename("Sky <script>alert(1)</script>")), "epub")
      File.write(repo.epub_path(fic_id, repo.epub_filename("Sky <script>alert(1)</script> - Vol <b>1</b>")), "epub")

      get "/"

      expect(last_response.body).to include("Sky &lt;script&gt;alert(1)&lt;/script&gt;")
      expect(last_response.body).to include("Vol &lt;b&gt;1&lt;/b&gt;")
      expect(last_response.body).not_to include("<script>alert(1)</script>")
      expect(last_response.body).not_to include("Vol <b>1</b>")
    end

    it "shows 'build pending' until an EPUB exists, then a download link" do
      follow_fic
      get "/"
      expect(last_response.body).to include("build pending")

      FileUtils.mkdir_p(repo.build_dir(fic_id))
      File.write(repo.epub_path(fic_id, "Sky Pride.epub"), "epub")
      get "/"
      expect(last_response.body).to include("/download/#{fic_id}")
      expect(last_response.body).not_to include("build pending")
    end

    it "shows per-story pull status" do
      follow_fic
      repo.append_pull_log(timestamp: Time.local(2026, 1, 2, 3, 4, 0).iso8601, fics: [{ fic_id: fic_id, title: "Sky Pride", new_chapters: ["Chapter 1"] }])

      get "/"

      expect(last_response.body).to include("last pull: 2026-01-02")
      expect(last_response.body).not_to include("last pull: 2026-01-02 03:04")
      expect(last_response.body).to include("1 new")
    end

    it "shows rough word counts from persisted fic and volume stats" do
      follow_fic(
        stats: { "word_count_estimate" => 1_249 },
        volumes: [{ "id" => 10395, "title" => "Volume 1", "word_count_estimate" => 10_600 }],
      )
      FileUtils.mkdir_p(repo.build_dir(fic_id))
      File.write(repo.epub_path(fic_id, "Sky Pride.epub"), "epub")
      File.write(repo.epub_path(fic_id, "Sky Pride - Volume 1.epub"), "epub")

      get "/"

      expect(last_response.body).to include("~1,200 words")
      expect(last_response.body).to include("~11,000 words")
    end

    it "renders no word-count text when persisted stats are absent" do
      follow_fic
      FileUtils.mkdir_p(repo.build_dir(fic_id))
      File.write(repo.epub_path(fic_id, "Sky Pride.epub"), "epub")

      get "/"

      expect(last_response.body).not_to include("words")
      expect(last_response.body).not_to include("word count pending")
    end

    it "does not read chapter contents for word-count stats" do
      follow_fic(stats: { "word_count_estimate" => 1_249 })
      write_chapter("2113501", "<p>#{Array.new(50_000, "word").join(" ")}</p>")
      allow(repo).to receive(:read_chapter_from_path).and_raise("chapter contents should not be read")
      allow(repo).to receive(:read_chapter).and_raise("chapter contents should not be read")

      get "/"

      expect(last_response).to be_ok
      expect(last_response.body).to include("~1,200 words")
    end
  end

  describe "POST /follow" do
    before do
      allow(mock_rr).to receive(:throttle=)
      allow(mock_rr).to receive(:chapter_overview).and_return([])
      allow(mock_rr).to receive(:fic_info).and_return(
        title: "Sky Pride", author: "Author", description: "d",
        cover_image: "img", volumes: [], volume_covers: {},
      )
    end

    it "registers the story and queues a build" do
      post "/follow", url: "https://www.royalroad.com/fiction/107917/sky-pride"
      expect(last_response.status).to eq 302
      expect(library.config.followed_stories).to include(fic_id)
      expect(jobs.runs).to eq 1
    end

    it "rejects a URL on an unsupported source with a flash and no job" do
      post "/follow", url: "https://example.com/fiction/1/"
      follow_redirect!
      expect(last_response.body).to include("is not a URL on a supported story source")
      expect(library.config.followed_stories).to be_empty
      expect(jobs.runs).to eq 0
    end

    it "escapes flash messages" do
      post "/follow", url: "https://example.com/<script>alert(1)</script>"
      follow_redirect!

      expect(last_response.body).to include("&lt;script&gt;alert(1)&lt;/script&gt;")
      expect(last_response.body).not_to include("<script>alert(1)</script>")
    end
  end

  describe "POST /pull" do
    it "starts a pull job" do
      post "/pull"
      expect(last_response.status).to eq 302
      expect(jobs.runs).to eq 1
    end
  end

  describe "POST /rename" do
    it "updates the display name and queues a rebuild" do
      follow_fic
      post "/rename", fic_id: fic_id, name: "Better Title"

      expect(last_response.status).to eq 302
      expect(repo.read_fic_info(fic_id)["display_name"]).to eq "Better Title"
      expect(jobs.runs).to eq 1
    end

    it "404s for a story that is not followed" do
      post "/rename", fic_id: "999999", name: "Nope"
      expect(last_response.status).to eq 404
      expect(jobs.runs).to eq 0
    end
  end

  describe "POST /unfollow" do
    it "removes the story from followed config" do
      follow_fic
      post "/unfollow", fic_id: fic_id

      expect(last_response.status).to eq 302
      expect(library.config.followed_stories).to be_empty
    end

    it "404s for a story that is not followed" do
      post "/unfollow", fic_id: "999999"
      expect(last_response.status).to eq 404
    end
  end

  describe "POST /rebuild" do
    it "starts a rebuild job" do
      post "/rebuild"
      expect(last_response.status).to eq 302
      expect(jobs.runs).to eq 1
    end
  end

  describe "GET /download" do
    it "serves the complete EPUB when built" do
      follow_fic
      FileUtils.mkdir_p(repo.build_dir(fic_id))
      File.write(repo.epub_path(fic_id, "Sky Pride.epub"), "epub-bytes")

      get "/download/#{fic_id}"
      expect(last_response).to be_ok
      expect(last_response.body).to eq "epub-bytes"
    end

    it "serves a volume EPUB by volume id" do
      follow_fic(volumes: [{ "id" => 10395, "title" => "Volume 1" }])
      FileUtils.mkdir_p(repo.build_dir(fic_id))
      File.write(repo.epub_path(fic_id, "Sky Pride - Volume 1.epub"), "vol-bytes")

      get "/download/#{fic_id}/volume/10395"
      expect(last_response).to be_ok
      expect(last_response.body).to eq "vol-bytes"
    end

    it "404s when the EPUB has not been built" do
      follow_fic
      get "/download/#{fic_id}"
      expect(last_response.status).to eq 404
    end

    it "404s for a story that is not followed" do
      get "/download/999999"
      expect(last_response.status).to eq 404
    end
  end
end
