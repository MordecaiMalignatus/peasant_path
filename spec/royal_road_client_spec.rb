require "peasant_path"

RSpec.describe PeasantPath::RoyalRoadClient do
  let(:client) { PeasantPath::RoyalRoadClient.new }
  let(:sky_pride_html) { File.read(File.expand_path("../data/sky-pride.html", __dir__)) }
  let(:chapter_1_html) { File.read(File.expand_path("../data/chapter-1.html", __dir__)) }

  describe ".extract_button_link" do
    it "should correctly extract nav-button links" do
      input = Nokogiri::XML.parse(<<~XML).css(".btn")[0]
        <a class="btn btn-primary col-xs-12" href="/fiction/107917/sky-pride/chapter/2113560/chapter-2--gourmet-in-the-garbage">
           Next <br class="visible-xs-block">Chapter <i class="far fa-chevron-double-right ml-3"></i>
        </a>
      XML
      expect(PeasantPath::RoyalRoadClient.extract_button_link(input)).to eq "/fiction/107917/sky-pride/chapter/2113560/chapter-2--gourmet-in-the-garbage"
    end

    it "should return nil when the button is disabled" do
      input = Nokogiri::XML.parse(<<~XML).css(".btn")[0]
        <button class="btn btn-primary col-xs-12" disabled="disabled">
            <i class="far fa-chevron-double-left mr-3"></i> Previous <br class="visible-xs-block">Chapter
        </button>
      XML

      expect(PeasantPath::RoyalRoadClient.extract_button_link(input)).to be_nil
    end
  end

  describe "#fic_info" do
    before do
      allow(PeasantPath::RoyalRoadClient).to receive(:get).and_return(
        double(code: 200, body: sky_pride_html)
      )
      allow(client).to receive(:download_picture).and_return("mock_image_data")
    end

    it "extracts the story title correctly" do
      result = client.fic_info("/fiction/107917/sky-pride")
      expect(result[:title]).to eq "Sky Pride"
    end

    it "extracts the author name correctly" do
      result = client.fic_info("/fiction/107917/sky-pride")
      expect(result[:author]).to eq "Warby Picus"
    end

    it "extracts the story description" do
      result = client.fic_info("/fiction/107917/sky-pride")
      expect(result[:description]).to start_with("What does it take to climb out of the trash and into the sky?")
      expect(result[:description]).to include("The very heavens had decreed his death")
    end

    it "downloads the cover image" do
      expect(client).to receive(:download_picture).with(
        "https://www.royalroadcdn.com/public/covers-large/107917-sky-pride.jpg?time=1759762861"
      )
      client.fic_info("/fiction/107917/sky-pride")
    end

    it "returns all required fields" do
      result = client.fic_info("/fiction/107917/sky-pride")
      expect(result).to have_key(:title)
      expect(result).to have_key(:author)
      expect(result).to have_key(:description)
      expect(result).to have_key(:cover_image)
      expect(result).to have_key(:volumes)
      expect(result).to have_key(:volume_covers)
    end

    it "extracts volumes" do
      result = client.fic_info("/fiction/107917/sky-pride")
      expect(result[:volumes]).to be_a(Array)
      expect(result[:volumes].size).to eq 4
    end

    it "extracts volume IDs and titles" do
      result = client.fic_info("/fiction/107917/sky-pride")
      first = result[:volumes].find { |v| v["order"] == 1 }
      expect(first["id"]).to eq 10395
      expect(first["title"]).to eq "Sky Pride V. 1 The Feral Daoist"
    end

    it "downloads a cover image for each volume" do
      expect(client).to receive(:download_picture).with(
        "https://www.royalroadcdn.com/public/volume-covers-large/107917-aacay9v76by-sky-pride-vol-1.jpg?time=1745199112"
      ).and_return("vol1_image")
      allow(client).to receive(:download_picture).and_return("mock_image_data")
      client.fic_info("/fiction/107917/sky-pride")
    end

    it "returns volume covers keyed by volume ID" do
      result = client.fic_info("/fiction/107917/sky-pride")
      expect(result[:volume_covers]).to be_a(Hash)
      expect(result[:volume_covers].keys).to contain_exactly(10395, 10397, 13235, 13278)
      expect(result[:volume_covers][10395]).to eq "mock_image_data"
    end
  end

  describe "#chapter_overview" do
    before do
      allow(PeasantPath::RoyalRoadClient).to receive(:get).with("/fiction/107917/").and_return(
        double(code: 200, body: sky_pride_html)
      )
    end

    it "returns an array of chapter hashes" do
      result = client.chapter_overview(107917)
      expect(result).to be_a(Array)
      expect(result).not_to be_empty
    end

    it "each chapter has required fields" do
      result = client.chapter_overview(107917)
      chapter = result.first
      expect(chapter).to have_key("id")
      expect(chapter).to have_key("title")
      expect(chapter).to have_key("url")
      expect(chapter).to have_key("volumeId")
      expect(chapter).to have_key("order")
    end

    it "extracts the first chapter correctly" do
      result = client.chapter_overview(107917)
      first = result.find { |c| c["order"] == 0 }
      expect(first["title"]).to eq "Chapter 1- In the Care of a Hateful God"
      expect(first["url"]).to eq "/fiction/107917/sky-pride/chapter/2113501/chapter-1--in-the-care-of-a-hateful-god"
    end

    it "extracts the first chapter's volume ID" do
      result = client.chapter_overview(107917)
      first = result.find { |c| c["order"] == 0 }
      expect(first["volumeId"]).to eq 10395
    end

    it "returns at least 10 chapters" do
      result = client.chapter_overview(107917)
      expect(result.size).to be >= 10
    end
  end

  describe "#enrich_overview_chapter!" do
    let(:repository) { instance_double(PeasantPath::DiskRepository) }
    let(:chapter) do
      PeasantPath::Chapter.new(
        "https://www.royalroad.com/fiction/107917/sky-pride/chapter/2113501/chapter-1--in-the-care-of-a-hateful-god",
        repository
      )
    end

    before do
      allow(PeasantPath::RoyalRoadClient).to receive(:get).with(chapter.uri).and_return(
        double(code: 200, body: chapter_1_html)
      )
    end

    it "removes Royal Road notices hidden from browsers" do
      result = client.enrich_overview_chapter!(chapter)

      expect(result.chapter_text).not_to include("Unlawfully taken from Royal Road")
      expect(result.chapter_text).not_to include("cjI1ODQzMGQzNmRjNDQ3ZjVhMjQ3MzkyMGIzMzM1MGJm")
      expect(result.chapter_text).to include("Where is my son? It is time for him to die.")
      expect(result.chapter_text).to include("This is usually the point where I say")
    end

    it "keeps classed chapter elements that are not hidden by the response stylesheet" do
      result = client.enrich_overview_chapter!(chapter)

      expect(result.chapter_text).to include("cnNiZmVmZWQ1Mzc4MjRjNzE4MWUxZmY5OWRkNWQ0ZDc4")
    end

    it "removes hidden content regardless of its wording or speak declaration" do
      text = enrich_chapter_with_css(
        ".random-a { display: none; } .random-b { display: none; speak: always; }",
        '<span class="random-a">An unfamiliar notice.</span>' \
        '<span class="random-b">Another unfamiliar notice.</span>' \
        '<p>This narrative has been purloined without the author\'s approval.</p>'
      )

      expect(text).not_to include("unfamiliar notice")
      expect(text).to include("purloined")
    end

    it "handles grouped selectors, comments, and important declarations" do
      text = enrich_chapter_with_css(
        ".random-a, .random-b { DISPLAY: /* hidden */ NoNe !important; }",
        '<span class="random-a">First notice.</span>' \
        '<span class="ordinary random-b">Second notice.</span><p>Visible story.</p>'
      )

      expect(text).not_to include("notice")
      expect(text).to include("Visible story.")
    end

    it "matches compound and scoped selectors without hiding unrelated classes" do
      text = enrich_chapter_with_css(
        ".chapter-content > span.notice.hidden { display: none; }",
        '<span class="notice hidden">Hidden notice.</span>' \
        '<span class="notice">Visible aside.</span><p class="hidden">Visible paragraph.</p>'
      )

      expect(text).not_to include("Hidden notice.")
      expect(text).to include("Visible aside.", "Visible paragraph.")
    end

    it "respects visible overrides across style blocks and selector specificity" do
      text = enrich_chapter_with_css(
        ".notice { display: none; } .chapter-content .kept { display: inline; }",
        '<span class="notice">Visible later override.</span>' \
        '<span class="notice kept">Visible more specific override.</span>',
        extra_head: "<style>.notice { display: inline; } .kept { display: none; }</style>",
      )

      expect(text).to include("Visible later override.", "Visible more specific override.")
    end

    it "keeps important hidden declarations ahead of later ordinary overrides" do
      text = enrich_chapter_with_css(
        ".notice { display: none !important; display: inline; }",
        '<span class="notice">Hidden notice.</span><p>Visible story.</p>',
        extra_head: "<style>.notice { display: inline; }</style>",
      )

      expect(text).not_to include("Hidden notice.")
      expect(text).to include("Visible story.")
    end

    it "resolves each grouped selector at its own specificity" do
      text = enrich_chapter_with_css(
        "#unrelated, .notice { display: none; } span.notice { display: inline; }",
        '<span class="notice">Visible more specific override.</span>'
      )

      expect(text).to include("Visible more specific override.")
    end

    it "respects inline display declarations and their importance" do
      text = enrich_chapter_with_css(
        ".notice { display: none; } .important { display: none !important; }",
        '<span class="notice" style="display:inline">Visible inline override.</span>' \
        '<span class="important" style="display:inline">Hidden important notice.</span>' \
        '<span class="important" style="display:inline!important">Visible important override.</span>' \
        '<span style="display:none">Hidden inline notice.</span>'
      )

      expect(text).to include("Visible inline override.", "Visible important override.")
      expect(text).not_to include("Hidden important notice.", "Hidden inline notice.")
    end

    it "does not apply conditional styles or state dependent selectors" do
      text = enrich_chapter_with_css(
        "@media print { .notice { display: none; } } .notice:hover { display: none; }",
        '<span class="notice">Visible notice-shaped story text.</span>',
        extra_head: '<style media="print">.notice { display: none; }</style>',
      )

      expect(text).to include("Visible notice-shaped story text.")
    end

    it "ignores invalid selectors without skipping subsequent hidden rules" do
      text = enrich_chapter_with_css(
        ".broken > { display: none; } .notice { display: none; }",
        '<span class="notice">Hidden notice.</span><p>Visible story.</p>'
      )

      expect(text).not_to include("Hidden notice.")
      expect(text).to include("Visible story.")
    end

    def enrich_chapter_with_css(styles, content, extra_head: "")
      html = <<~HTML
        <html><head><style>#{styles}</style>#{extra_head}</head><body>
          <div class="nav-buttons"><a class="btn" disabled>Previous</a><a class="btn" disabled>Next</a></div>
          <div class="col-md-5 col-lg-6 col-md-offset-1"><h1>Test chapter</h1></div>
          <div class="chapter-content">#{content}</div>
        </body></html>
      HTML
      allow(PeasantPath::RoyalRoadClient).to receive(:get).with(chapter.uri).and_return(
        double(code: 200, body: html)
      )
      client.enrich_overview_chapter!(chapter).chapter_text
    end
  end

  describe "scraping guard rails" do
    it "raises a named ScrapeError when window.volumes is missing from fic_info" do
      allow(PeasantPath::RoyalRoadClient).to receive(:get).and_return(double(code: 200, body: "<html>rate limited</html>"))
      allow(client).to receive(:download_picture).and_return("x")

      expect {
        client.fic_info("/fiction/107917/sky-pride")
      }.to raise_error(PeasantPath::RoyalRoadClient::ScrapeError, /window\.volumes/)
    end

    it "raises a named ScrapeError when window.chapters is missing from chapter_overview" do
      allow(PeasantPath::RoyalRoadClient).to receive(:get).with("/fiction/107917/").and_return(
        double(code: 200, body: "<html>error page</html>")
      )

      expect {
        client.chapter_overview(107917)
      }.to raise_error(PeasantPath::RoyalRoadClient::ScrapeError, /fiction 107917.*window\.chapters/m)
    end

    it "raises a named ScrapeError when RoyalRoad returns 429" do
      allow(PeasantPath::RoyalRoadClient).to receive(:get).with("/fiction/107917/").and_return(
        double(code: 429, body: "rate limited")
      )

      expect {
        client.chapter_overview(107917)
      }.to raise_error(PeasantPath::RoyalRoadClient::ScrapeError, /429 Too Many Requests/)
    end

    it "raises a named ScrapeError when RoyalRoad returns a server error" do
      allow(PeasantPath::RoyalRoadClient).to receive(:get).with("/fiction/107917/").and_return(
        double(code: 503, body: "unavailable")
      )

      expect {
        client.chapter_overview(107917)
      }.to raise_error(PeasantPath::RoyalRoadClient::ScrapeError, /503 server error/)
    end
  end

  describe "#download_picture" do
    it "downloads image data successfully" do
      mock_response = double(code: 200, body: "fake_image_data")
      allow(HTTParty).to receive(:get).with("https://example.com/image.jpg", anything).and_return(mock_response)

      result = client.download_picture("https://example.com/image.jpg")
      expect(result).to eq "fake_image_data"
    end

    it "raises an error on non-200 response" do
      mock_response = double(code: 404, inspect: "404 Not Found")
      allow(HTTParty).to receive(:get).with("https://example.com/missing.jpg", anything).and_return(mock_response)

      expect {
        client.download_picture("https://example.com/missing.jpg")
      }.to raise_error(PeasantPath::RoyalRoadClient::ScrapeError, /cover_image: got unexpected response code/)
    end
  end
end
