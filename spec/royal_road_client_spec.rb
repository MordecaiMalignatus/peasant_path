require "peasant_road"

RSpec.describe PeasantRoad::RoyalRoadClient do
  let(:client) { PeasantRoad::RoyalRoadClient.new }
  let(:sky_pride_html) { File.read(File.expand_path("../data/sky-pride.html", __dir__)) }
  let(:chapter_1_html) { File.read(File.expand_path("../data/chapter-1.html", __dir__)) }

  describe ".extract_button_link" do
    it "should correctly extract nav-button links" do
      input = Nokogiri::XML.parse(<<~XML).css(".btn")[0]
        <a class="btn btn-primary col-xs-12" href="/fiction/107917/sky-pride/chapter/2113560/chapter-2--gourmet-in-the-garbage">
           Next <br class="visible-xs-block">Chapter <i class="far fa-chevron-double-right ml-3"></i>
        </a>
      XML
      expect(PeasantRoad::RoyalRoadClient.extract_button_link(input)).to eq "/fiction/107917/sky-pride/chapter/2113560/chapter-2--gourmet-in-the-garbage"
    end

    it "should return nil when the button is disabled" do
      input = Nokogiri::XML.parse(<<~XML).css(".btn")[0]
        <button class="btn btn-primary col-xs-12" disabled="disabled">
            <i class="far fa-chevron-double-left mr-3"></i> Previous <br class="visible-xs-block">Chapter
        </button>
      XML

      expect(PeasantRoad::RoyalRoadClient.extract_button_link(input)).to be_nil
    end
  end

  describe "#fic_info" do
    before do
      allow(PeasantRoad::RoyalRoadClient).to receive(:get).and_return(
        double(body: sky_pride_html)
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
    end
  end

  describe "#chapter_overview" do
    before do
      allow(PeasantRoad::RoyalRoadClient).to receive(:get).with("/fiction/107917/").and_return(
        double(body: sky_pride_html)
      )
    end

    it "extracts chapter titles and URLs" do
      result = client.chapter_overview(107917)
      expect(result).to be_a(Hash)
      expect(result).not_to be_empty
    end

    it "extracts the first chapter correctly" do
      result = client.chapter_overview(107917)
      expect(result["Chapter 1- In the Care of a Hateful God"]).to eq "/fiction/107917/sky-pride/chapter/2113501/chapter-1--in-the-care-of-a-hateful-god"
    end

    it "extracts multiple chapters" do
      result = client.chapter_overview(107917)
      expect(result.keys).to include(
        "Chapter 1- In the Care of a Hateful God",
        "Chapter 2- Gourmet in the Garbage",
        "Chapter 3- Junkyard Classroom, Trash Heap Hospital",
        "Chapter 4- First Steps on the Path",
        "Chapter 5- Child of Destiny"
      )
    end

    it "maps chapter titles to correct URLs" do
      result = client.chapter_overview(107917)
      expect(result["Chapter 2- Gourmet in the Garbage"]).to eq "/fiction/107917/sky-pride/chapter/2113560/chapter-2--gourmet-in-the-garbage"
      expect(result["Chapter 10- Ruthless Child"]).to eq "/fiction/107917/sky-pride/chapter/2115445/chapter-10--ruthless-child"
    end

    it "returns at least 10 chapters" do
      result = client.chapter_overview(107917)
      expect(result.size).to be >= 10
    end
  end

  describe "#fetch_chapter" do
    let(:chapter_uri) { "https://www.royalroad.com/fiction/107917/sky-pride/chapter/2113501/chapter-1--in-the-care-of-a-hateful-god" }
    let(:mock_repo) { double("DiskRepository") }

    before do
      allow(PeasantRoad::RoyalRoadClient).to receive(:get).with(chapter_uri).and_return(
        double(body: chapter_1_html)
      )
    end

    it "returns a Chapter object" do
      result = client.fetch_chapter(chapter_uri, mock_repo)
      expect(result).to be_a(PeasantRoad::Chapter)
    end

    it "extracts the chapter title correctly" do
      result = client.fetch_chapter(chapter_uri, mock_repo)
      expect(result.chapter_title).to eq "Chapter 1- In the Care of a Hateful God"
    end

    it "extracts the chapter content" do
      result = client.fetch_chapter(chapter_uri, mock_repo)
      expect(result.chapter_text).to include("Where is my son? It is time for him to die.")
      expect(result.chapter_text).to include("chapter-content")
    end

    it "preserves HTML formatting in chapter text" do
      result = client.fetch_chapter(chapter_uri, mock_repo)
      expect(result.chapter_text).to include("<p")
      expect(result.chapter_text).to include("</p>")
    end

    it "sets navigation correctly for first chapter" do
      result = client.fetch_chapter(chapter_uri, mock_repo)
      expect(result.previous_chapter).to be_nil
      expect(result.next_chapter).to eq "/fiction/107917/sky-pride/chapter/2113560/chapter-2--gourmet-in-the-garbage"
    end

    it "parses fic_id and chapter_id from URI" do
      result = client.fetch_chapter(chapter_uri, mock_repo)
      expect(result.fic_id).to eq "107917"
      expect(result.chapter_id).to eq "2113501"
    end

    it "stores the original URI" do
      result = client.fetch_chapter(chapter_uri, mock_repo)
      expect(result.uri).to eq chapter_uri
    end
  end

  describe "#download_picture" do
    it "downloads image data successfully" do
      mock_response = double(code: 200, body: "fake_image_data")
      allow(HTTParty).to receive(:get).with("https://example.com/image.jpg").and_return(mock_response)

      result = client.download_picture("https://example.com/image.jpg")
      expect(result).to eq "fake_image_data"
    end

    it "raises an error on non-200 response" do
      mock_response = double(code: 404, inspect: "404 Not Found")
      allow(HTTParty).to receive(:get).with("https://example.com/missing.jpg").and_return(mock_response)

      expect {
        client.download_picture("https://example.com/missing.jpg")
      }.to raise_error(/cover_image: got unexpected response code/)
    end
  end
end
