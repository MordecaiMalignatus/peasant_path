require "peasant_path"

RSpec.describe PeasantPath::FanFictionNetClient do
  let(:client) { PeasantPath::FanFictionNetClient.new }
  let(:chapter_1_html) { File.read(File.expand_path("../data/ffn-chapter-1.html", __dir__)) }
  let(:chapter_2_html) { File.read(File.expand_path("../data/ffn-chapter-2.html", __dir__)) }
  let(:single_chapter_html) { File.read(File.expand_path("../data/ffn-single-chapter.html", __dir__)) }
  let(:chapter_1_doc) { Nokogiri::HTML(chapter_1_html) }
  let(:chapter_2_doc) { Nokogiri::HTML(chapter_2_html) }
  let(:single_chapter_doc) { Nokogiri::HTML(single_chapter_html) }
  let(:mock_repo) { double("DiskRepository") }

  describe ".story_uri" do
    it "builds the canonical story URL (chapter 1, since there's no overview page)" do
      expect(described_class.story_uri("8872491")).to eq "https://www.fanfiction.net/s/8872491/1/"
    end
  end

  describe ".native_fic_id_from_url" do
    it "extracts the fic ID from a story URL" do
      expect(described_class.native_fic_id_from_url("https://www.fanfiction.net/s/8872491/1/Test-Story-Alpha")).to eq "8872491"
    end

    it "returns nil for an unrelated URL" do
      expect(described_class.native_fic_id_from_url("https://www.fanfiction.net/")).to be_nil
    end
  end

  describe ".chapter_ids_from_url" do
    it "extracts the fic ID and chapter number from a chapter URL" do
      expect(described_class.chapter_ids_from_url("https://www.fanfiction.net/s/8872491/2/Test-Story-Alpha")).to eq ["8872491", "2"]
    end

    it "returns nil for a URL with no chapter number" do
      expect(described_class.chapter_ids_from_url("https://www.fanfiction.net/s/8872491/")).to be_nil
    end
  end

  describe "#fic_info" do
    before { allow(client).to receive(:fetch).and_return(chapter_1_doc) }

    it "extracts the story title" do
      expect(client.fic_info("https://www.fanfiction.net/s/8872491/1/")[:title]).to eq "Test Story Alpha"
    end

    it "extracts the author" do
      expect(client.fic_info("https://www.fanfiction.net/s/8872491/1/")[:author]).to eq "Test Author"
    end

    it "extracts the description" do
      expect(client.fic_info("https://www.fanfiction.net/s/8872491/1/")[:description]).to start_with("Lorem ipsum dolor sit amet")
    end

    it "downloads the cover image from the resolved absolute URL" do
      allow(HTTParty).to receive(:get).with("https://www.fanfiction.net/image/2269136/75/").and_return(double(code: 200, body: "image bytes"))
      expect(client.fic_info("https://www.fanfiction.net/s/8872491/1/")[:cover_image]).to eq "image bytes"
    end

    it "returns no volumes, since FanFiction.net has no volume concept" do
      result = client.fic_info("https://www.fanfiction.net/s/8872491/1/")
      expect(result[:volumes]).to eq []
      expect(result[:volume_covers]).to eq({})
    end

    it "still extracts metadata from a single-chapter story's page" do
      allow(client).to receive(:fetch).and_return(single_chapter_doc)
      result = client.fic_info("https://www.fanfiction.net/s/12417635/1/")

      expect(result[:title]).to eq "Test Story Beta"
      expect(result[:author]).to eq "Test Author"
    end
  end

  describe "#chapter_overview" do
    before { allow(client).to receive(:fetch).and_return(chapter_1_doc) }

    it "returns one entry per option in the chapter dropdown" do
      expect(client.chapter_overview("fanfictionnet:8872491").size).to eq 2
    end

    it "strips the site-generated numbering prefix from chapter titles" do
      titles = client.chapter_overview("fanfictionnet:8872491").map { |c| c["title"] }
      expect(titles).to eq ["Chapter 1", "Chapter 2"]
    end

    it "assigns zero-based order matching chapter position" do
      orders = client.chapter_overview("fanfictionnet:8872491").map { |c| c["order"] }
      expect(orders).to eq [0, 1]
    end

    it "builds absolute chapter URLs from the native fic ID" do
      urls = client.chapter_overview("fanfictionnet:8872491").map { |c| c["url"] }
      expect(urls).to eq [
                           "https://www.fanfiction.net/s/8872491/1/",
                           "https://www.fanfiction.net/s/8872491/2/",
                         ]
    end

    context "when the story has only one chapter (no #chap_select dropdown)" do
      before { allow(client).to receive(:fetch).and_return(single_chapter_doc) }

      it "returns a single chapter 1 entry instead of raising" do
        result = client.chapter_overview("fanfictionnet:12417635")

        expect(result).to eq [{
                               "title" => "Chapter 1",
                               "order" => 0,
                               "url" => "https://www.fanfiction.net/s/12417635/1/",
                             }]
      end
    end
  end

  describe "#enrich_overview_chapter!" do
    it "fills in chapter text from #storytext" do
      chapter = PeasantPath::Chapter.from_overview_hash(
        { "title" => "Chapter 2", "order" => 1, "url" => "https://www.fanfiction.net/s/8872491/2/" }, mock_repo
      )
      allow(client).to receive(:fetch).and_return(chapter_2_doc)

      client.enrich_overview_chapter!(chapter)

      expect(chapter.chapter_text).to include('id="storytext"')
      expect(chapter.chapter_text).to include("Lorem ipsum")
    end
  end

  describe "fetch memoization" do
    it "reuses the immediately preceding fetch for the same url, instead of loading it again" do
      allow(client).to receive(:fetch_page).and_return(chapter_1_doc)

      client.chapter_overview("fanfictionnet:8872491")
      client.fic_info("https://www.fanfiction.net/s/8872491/1/")

      expect(client).to have_received(:fetch_page).once
    end

    it "fetches again for a different url" do
      allow(client).to receive(:fetch_page).and_return(chapter_1_doc, chapter_2_doc)
      chapter = PeasantPath::Chapter.from_overview_hash(
        { "title" => "Chapter 2", "order" => 1, "url" => "https://www.fanfiction.net/s/8872491/2/" }, mock_repo
      )

      client.fic_info("https://www.fanfiction.net/s/8872491/1/")
      client.enrich_overview_chapter!(chapter)

      expect(client).to have_received(:fetch_page).twice
    end

    it "fetches again for the same url once a different one has come in between" do
      allow(client).to receive(:fetch_page).and_return(chapter_1_doc, chapter_2_doc, chapter_1_doc)
      chapter = PeasantPath::Chapter.from_overview_hash(
        { "title" => "Chapter 2", "order" => 1, "url" => "https://www.fanfiction.net/s/8872491/2/" }, mock_repo
      )

      client.fic_info("https://www.fanfiction.net/s/8872491/1/")
      client.enrich_overview_chapter!(chapter)
      client.fic_info("https://www.fanfiction.net/s/8872491/1/")

      expect(client).to have_received(:fetch_page).exactly(3).times
    end
  end

  describe "error handling" do
    let(:chapter) do
      PeasantPath::Chapter.from_overview_hash(
        { "title" => "Chapter 1", "order" => 0, "url" => "https://www.fanfiction.net/s/8872491/1/" }, mock_repo
      )
    end

    it "raises ScrapeError when #storytext is missing from the page" do
      allow(client).to receive(:fetch).and_return(Nokogiri::HTML("<html><body>nope</body></html>"))

      expect { client.enrich_overview_chapter!(chapter) }.to raise_error(described_class::ScrapeError, /storytext/)
    end

    it "raises ScrapeError when a Cloudflare challenge page is served instead of real content" do
      mock_browser = instance_double(Ferrum::Browser, goto: true, body: "<html><head><title>Just a moment...</title></head></html>", quit: true)
      allow(mock_browser).to receive(:headers).and_return(double(set: true))
      allow(Ferrum::Browser).to receive(:new).and_return(mock_browser)
      allow(client).to receive(:sleep)

      expect { client.fic_info("https://www.fanfiction.net/s/8872491/1/") }.to raise_error(described_class::ScrapeError, /Cloudflare/)
    end
  end
end
