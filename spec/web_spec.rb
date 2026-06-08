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
  let(:library) { PeasantPath::Library.new(repo: repo) }
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

  before do
    PeasantPath::Web.set(:library, library)
    PeasantPath::Web.set(:jobs, jobs)
    PeasantPath::Web.set(:app_logger, Logger.new(File::NULL))
  end

  after { FileUtils.rm_rf(tmpdir) }

  def follow_fic(title: "Sky Pride", volumes: [])
    repo.write_config_file(JSON.generate(followed_stories: [fic_id]))
    repo.write_fic_info(fic_id, JSON.generate(title: title, author: "Author", volumes: volumes))
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
  end

  describe "POST /follow" do
    before do
      mock_rr = instance_double(PeasantPath::RoyalRoadClient)
      allow(PeasantPath::RoyalRoadClient).to receive(:new).and_return(mock_rr)
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

    it "rejects a non-RoyalRoad URL with a flash and no job" do
      post "/follow", url: "https://example.com/fiction/1/"
      follow_redirect!
      expect(last_response.body).to include("is not a RoyalRoad URL")
      expect(library.config.followed_stories).to be_empty
      expect(jobs.runs).to eq 0
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
