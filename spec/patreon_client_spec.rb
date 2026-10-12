require "peasant_path"
require "peasant_path/patreon_client"
require "json"
require "logger"
require "stringio"
require "time"

module PatreonClientSpecSupport
  FIXTURES = File.expand_path("../data/patreon", __dir__)

  # A transport that answers from a url => [status, body] table and records
  # every URL it was asked for, so pagination behaviour can be asserted.
  class FakeTransport
    attr_reader :calls
    attr_accessor :landing_title

    def initialize(routes)
      @routes = routes
      @calls = []
      @landing_title = "Home | Patreon"
    end

    def get_json(url) = answer(url)
    def get_text(url) = answer(url)
    def get_bytes(url) = answer(url)

    private

    def answer(url)
      @calls << url
      @routes.fetch(url) { raise "unexpected request #{url}" }
    end
  end
end

RSpec.describe PeasantPath::PatreonClient do
  FIXTURES = PatreonClientSpecSupport::FIXTURES

  def fixture_json(name)
    JSON.parse(File.read(File.join(FIXTURES, name)))
  end

  let(:repo) { instance_double(PeasantPath::DiskRepository) }
  let(:collection_fic) { double("Fic", fic_id: "patreon-col-1522125", uri: "https://www.patreon.com/collection/1522125", repository: repo, source_ref: { "collection_id" => "1522125" }) }
  let(:creator_fic) { double("Fic", fic_id: "patreon-v-u84402213", uri: "https://www.patreon.com/u84402213/posts", repository: repo, source_ref: { "vanity" => "u84402213", "campaign_id" => "9755002" }) }
  let(:current_user_url) { "https://www.patreon.com/api/current_user?json-api-version=1.0" }

  let(:collection_url) { "https://www.patreon.com/api/collection/1522125?json-api-version=1.0" }
  let(:campaign_url) { "https://www.patreon.com/api/campaigns/9755002?fields[campaign]=name,vanity,url,avatar_photo_url,summary&json-api-version=1.0" }
  let(:page1_url) { "https://www.patreon.com/api/posts?filter[campaign_id]=9755002&filter[collection_id]=1522125&filter[contains_exclusive_posts]=true&filter[is_draft]=false&sort=collection_order&json-api-version=1.0" }
  let(:page2_url) { fixture_json("posts_page1.json")["links"]["next"] }
  let(:thumb_url) { fixture_json("collection.json")["data"]["attributes"]["thumbnail"]["url"] }

  let(:routes) do
    {
      collection_url => [200, fixture_json("collection.json")],
      campaign_url => [200, fixture_json("campaign.json")],
      page1_url => [200, fixture_json("posts_page1.json")],
      page2_url => [200, fixture_json("posts_page2.json")],
      thumb_url => [200, "cover-bytes"],
    }
  end
  let(:transport) { PatreonClientSpecSupport::FakeTransport.new(routes) }
  let(:log) { StringIO.new }
  let(:client) { described_class.new(transport: transport, logger: Logger.new(log)) }

  before { allow(client).to receive(:sleep) }

  describe "#fic_info" do
    it "builds collection metadata from the collection and campaign endpoints" do
      info = client.fic_info(collection_fic)

      expect(info[:title]).to eq "Path of the Deathless"
      expect(info[:author]).to eq "Example Creator"
      expect(info[:description]).to eq "Greetings,\n\nI write fiction. Discord"
      expect(info[:cover_image]).to eq "cover-bytes"
      expect(info[:volumes]).to eq []
      expect(info[:volume_covers]).to eq({})
    end

    it "derives the campaign id from the thumbnail URL and records the vanity" do
      info = client.fic_info(collection_fic)
      expect(info[:source_ref]).to eq("collection_id" => "1522125", "campaign_id" => "9755002", "vanity" => "u84402213")
    end

    it "fetches the collection once per client even though fic_info and chapter_overview both need it" do
      client.fic_info(collection_fic)
      client.chapter_overview(collection_fic, known_ids: [])

      expect(transport.calls.count(collection_url)).to eq 1
    end

    it "builds creator metadata from the campaign, using the avatar as cover" do
      avatar = fixture_json("campaign.json")["data"]["attributes"]["avatar_photo_url"]
      routes[avatar] = [200, "avatar-bytes"]

      info = client.fic_info(creator_fic)
      expect(info[:title]).to eq "Example Creator"
      expect(info[:cover_image]).to eq "avatar-bytes"
      expect(info[:source_ref]["vanity"]).to eq "u84402213"
    end

    it "resolves a creator known only by vanity through the creator page" do
      routes["https://www.patreon.com/u84402213"] = [200, File.read(File.join(FIXTURES, "creator_page.html"))]
      routes[fixture_json("campaign.json")["data"]["attributes"]["avatar_photo_url"]] = [200, "avatar-bytes"]
      fic = double("Fic", fic_id: "patreon-v-u84402213", uri: "x", repository: repo, source_ref: { "vanity" => "u84402213" })

      info = client.fic_info(fic)
      expect(info[:source_ref]["campaign_id"]).to eq "9755002"
    end
  end

  describe "#resolve_campaign_id" do
    it "reads the escaped bootstrap JSON out of a creator page" do
      routes["https://www.patreon.com/u84402213"] = [200, File.read(File.join(FIXTURES, "creator_page.html"))]
      expect(client.resolve_campaign_id("u84402213")).to eq "9755002"
    end

    it "also matches unescaped JSON" do
      routes["https://www.patreon.com/x"] = [200, %({"pageBootstrap":{"campaign":{"data":{"id":"42"}}}})]
      expect(client.resolve_campaign_id("x")).to eq "42"
    end

    it "raises a named ScrapeError when the id is absent" do
      routes["https://www.patreon.com/x"] = [200, "<html>nope</html>"]
      expect { client.resolve_campaign_id("x") }.to raise_error(described_class::ScrapeError, /creator page x/)
    end
  end

  describe "#chapter_overview for a collection" do
    it "walks every page on a first pull and returns chapters in reading order" do
      chapters = client.chapter_overview(collection_fic, known_ids: [])

      expect(chapters.map(&:chapter_id)).to eq %w[100 200 300]
      expect(chapters.map(&:order_number)).to eq [0, 2, 3]
      expect(transport.calls).to include(page1_url, page2_url)
    end

    it "builds Patreon-sourced chapters with converted bodies" do
      chapter = client.chapter_overview(collection_fic, known_ids: []).first

      expect(chapter.source).to eq PeasantPath::Sources::PATREON
      expect(chapter.fic_id).to eq "patreon-col-1522125"
      expect(chapter.uri).to eq "https://www.patreon.com/u84402213/posts/1-first-100"
      expect(chapter.chapter_title).to eq "1  First"
      expect(chapter.published_at).to eq "2026-03-01T10:00:00.000+00:00"
      expect(chapter.chapter_text).to eq %(<div class="chapter-content"><p><strong>Path</strong></p><p>The first chapter begins. Nothing else happens.</p></div>)
      expect(chapter.volume_id).to be_nil
    end

    it "keeps the centred epigraph" do
      chapter = client.chapter_overview(collection_fic, known_ids: []).last
      expect(chapter.chapter_text).to include %(<p style="text-align:center"><em>An epigraph sits here.</em></p>)
    end

    it "stops after the first page where every post is known" do
      chapters = client.chapter_overview(collection_fic, known_ids: %w[100 200 300])

      expect(chapters).to be_empty
      expect(transport.calls).to include(page1_url)
      expect(transport.calls).not_to include(page2_url)
    end

    it "returns only new chapters on an incremental pull" do
      chapters = client.chapter_overview(collection_fic, known_ids: %w[100 200])
      expect(chapters.map(&:chapter_id)).to eq %w[300]
    end

    it "re-walks every page when the collection reports more posts than we hold" do
      # Everything on page 1 is known, but we only know 2 of the 3 posts the
      # collection reports, so the early stop must be overridden.
      chapters = client.chapter_overview(collection_fic, known_ids: %w[200 300])

      expect(chapters.map(&:chapter_id)).to eq %w[100]
      expect(transport.calls.count(page1_url)).to eq 2
      expect(transport.calls).to include(page2_url)
    end

    it "does not re-walk when a known post has merely left the collection" do
      # 999 is on disk but no longer in post_ids: we still hold all 3 of the
      # posts the collection reports, so one page is enough.
      chapters = client.chapter_overview(collection_fic, known_ids: %w[100 200 300 999])

      expect(chapters).to be_empty
      expect(transport.calls.count(page1_url)).to eq 1
      expect(transport.calls).not_to include(page2_url)
    end

    it "defers a post the list returns but post_ids does not know yet" do
      page = fixture_json("posts_page1.json")
      stray = JSON.parse(JSON.generate(page["data"][0]))
      stray["id"] = "777"
      page["data"] << stray
      routes[page1_url] = [200, page]

      chapters = client.chapter_overview(collection_fic, known_ids: [])

      expect(chapters.map(&:chapter_id)).to eq %w[100 200 300]
      expect(log.string).to match(/post 777.*deferred to the next pull/)
    end

    it "skips posts the account cannot view, without persisting them" do
      page = fixture_json("posts_page1.json")
      page["data"][0]["attributes"]["current_user_can_view"] = false
      page["data"][0]["attributes"]["content_json_string"] = nil
      routes[page1_url] = [200, page]

      chapters = client.chapter_overview(collection_fic, known_ids: [])
      expect(chapters.map(&:chapter_id)).to eq %w[100 200]
    end

    it "skips posts with an empty body" do
      page = fixture_json("posts_page1.json")
      page["data"][1]["attributes"]["content_json_string"] = ""
      routes[page1_url] = [200, page]

      expect(client.chapter_overview(collection_fic, known_ids: []).map(&:chapter_id)).to eq %w[100 300]
    end

    it "drops posts that have no readable text after conversion" do
      page = fixture_json("posts_page1.json")
      page["data"][1]["attributes"]["content_json_string"] = JSON.generate("type" => "doc", "content" => [{ "type" => "image" }])
      routes[page1_url] = [200, page]

      expect(client.chapter_overview(collection_fic, known_ids: []).map(&:chapter_id)).to eq %w[100 300]
    end

    it "falls back to the publication date when a title is blank" do
      page = fixture_json("posts_page2.json")
      page["data"][0]["attributes"]["title"] = " "
      routes[page2_url] = [200, page]

      expect(client.chapter_overview(collection_fic, known_ids: []).first.chapter_title).to eq "2026-03-01T10:00:00.000+00:00"
    end

    it "throttles between pages when asked" do
      client.throttle = true
      client.chapter_overview(collection_fic, known_ids: [])
      expect(client).to have_received(:sleep).once
    end

    it "raises ScrapeError on malformed body JSON" do
      page = fixture_json("posts_page2.json")
      page["data"][0]["attributes"]["content_json_string"] = "{not json"
      routes[page2_url] = [200, page]

      expect { client.chapter_overview(collection_fic, known_ids: []) }.to raise_error(described_class::ScrapeError, /post 100.*not valid JSON/)
    end
  end

  describe "#chapter_overview for a creator feed" do
    let(:feed1_url) { "https://www.patreon.com/api/posts?filter[campaign_id]=9755002&filter[contains_exclusive_posts]=true&filter[is_draft]=false&sort=-published_at&json-api-version=1.0" }

    before do
      page1 = fixture_json("posts_page1.json")
      page1["links"]["next"] = "#{feed1_url}&page[cursor]=zzz"
      routes[feed1_url] = [200, page1]
      routes["#{feed1_url}&page[cursor]=zzz"] = [200, fixture_json("posts_page2.json")]
    end

    def epoch(iso) = Time.iso8601(iso).to_i

    it "walks the whole feed and orders by publication timestamp" do
      chapters = client.chapter_overview(creator_fic, known_ids: [])
      expect(chapters.map(&:chapter_id)).to eq %w[100 200 300]
      expect(chapters.map(&:order_number)).to eq [
                                                   epoch("2026-03-01T10:00:00.000+00:00"),
                                                   epoch("2026-03-02T10:00:00.000+00:00"),
                                                   epoch("2026-03-03T10:00:00.000+00:00"),
                                                 ]
    end

    it "gives a new chapter an order that cannot collide with persisted ones even after older posts vanish" do
      # 100 was pulled earlier and has since been deleted from the feed; 300
      # is new. Its order must come from its own timestamp, not from its rank
      # among whatever is visible today (which would be 1, colliding with 200).
      page1 = fixture_json("posts_page1.json")
      page1["links"] = {}
      routes[feed1_url] = [200, page1]

      chapters = client.chapter_overview(creator_fic, known_ids: %w[100 200])

      expect(chapters.map(&:chapter_id)).to eq %w[300]
      expect(chapters.first.order_number).to eq epoch("2026-03-03T10:00:00.000+00:00")
      expect(chapters.first.order_number).to be > epoch("2026-03-02T10:00:00.000+00:00")
    end

    it "always walks every page of a creator feed, returning only new chapters" do
      chapters = client.chapter_overview(creator_fic, known_ids: %w[100 200])
      expect(chapters.map(&:chapter_id)).to eq %w[300]
      expect(transport.calls).to include("#{feed1_url}&page[cursor]=zzz")
    end

    it "raises ScrapeError when a post has no usable publication timestamp" do
      page1 = fixture_json("posts_page1.json")
      page1["data"][0]["attributes"]["published_at"] = "yesterday"
      routes[feed1_url] = [200, page1]

      expect { client.chapter_overview(creator_fic, known_ids: []) }.to raise_error(described_class::ScrapeError, /post 300.*published_at/)
    end
  end

  describe "#enrich_overview_chapter!" do
    it "is a no-op because the list endpoint already carried the body" do
      chapter = PeasantPath::Chapter.new("https://www.patreon.com/posts/1", fic_id: "patreon-col-1", chapter_id: "1", source: "patreon", repository: repo)
      expect(client.enrich_overview_chapter!(chapter)).to equal chapter
    end
  end

  describe "#verify_login!" do
    it "is true when the API reports a logged-in user" do
      routes[current_user_url] = [200, { "data" => { "id" => "1", "type" => "user" } }]
      expect(client.verify_login!).to be true
    end

    it "raises AuthRequired when the session has expired" do
      routes[current_user_url] = [401, { "errors" => [{ "code_name" => "LoginRequired" }] }]
      expect { client.verify_login! }.to raise_error(described_class::AuthRequired, /not logged in.*patreon login/)
    end

    it "raises AuthRequired when the browser is sitting on a Cloudflare challenge" do
      transport.landing_title = "Just a moment..."
      expect { client.verify_login! }.to raise_error(described_class::AuthRequired, /Cloudflare/)
      expect(transport.calls).to be_empty
    end
  end

  describe "authentication and scraping guard rails" do
    it "raises AuthRequired on 401" do
      routes[collection_url] = [401, { "errors" => [{ "code_name" => "LoginRequired" }] }]
      expect { client.fic_info(collection_fic) }.to raise_error(described_class::AuthRequired, /HTTP 401.*patreon login/)
    end

    it "raises AuthRequired on 403" do
      routes[page1_url] = [403, nil]
      expect { client.chapter_overview(collection_fic, known_ids: []) }.to raise_error(described_class::AuthRequired, /HTTP 403/)
    end

    it "raises AuthRequired when the browser is sitting on a Cloudflare challenge" do
      transport.landing_title = "Just a moment..."
      expect { client.fic_info(collection_fic) }.to raise_error(described_class::AuthRequired, /Cloudflare/)
    end

    it "raises ScrapeError on 429" do
      routes[collection_url] = [429, nil]
      expect { client.fic_info(collection_fic) }.to raise_error(described_class::ScrapeError, /429/)
    end

    it "raises ScrapeError naming the endpoint when the payload is missing data" do
      routes[collection_url] = [200, { "data" => nil }]
      expect { client.fic_info(collection_fic) }.to raise_error(described_class::ScrapeError, /collection 1522125/)
    end

    it "raises ScrapeError when the campaign id cannot be derived from the thumbnail" do
      body = fixture_json("collection.json")
      body["data"]["attributes"]["thumbnail"]["url"] = "https://example.com/no-campaign.png"
      routes[collection_url] = [200, body]
      expect { client.fic_info(collection_fic) }.to raise_error(described_class::ScrapeError, /thumbnail/)
    end

    it "tolerates a transport without landing_title" do
      bare = Class.new do
        def initialize(routes) = @routes = routes
        def get_json(url) = @routes.fetch(url)
        def get_text(url) = @routes.fetch(url)
        def get_bytes(url) = @routes.fetch(url)
      end.new(routes)
      expect(described_class.new(transport: bare).fic_info(collection_fic)[:title]).to eq "Path of the Deathless"
    end
  end
end
