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
      allow(PeasantRoad::RoyalRoadClient).to receive(:get).with("/fiction/107917/").and_return(
        double(body: sky_pride_html)
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
