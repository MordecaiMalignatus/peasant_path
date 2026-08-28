require "peasant_path"

RSpec.describe PeasantPath::Sources do
  describe ".key_for_fic_id" do
    it "treats an unprefixed fic_id as royalroad" do
      expect(described_class.key_for_fic_id("107917")).to eq "royalroad"
    end

    it "reads the prefix off a scoped fic_id" do
      expect(described_class.key_for_fic_id("othersource:12345")).to eq "othersource"
    end
  end

  describe ".native_id_for_fic_id" do
    it "returns an unprefixed fic_id as-is" do
      expect(described_class.native_id_for_fic_id("107917")).to eq "107917"
    end

    it "strips the source prefix from a scoped fic_id" do
      expect(described_class.native_id_for_fic_id("othersource:12345")).to eq "12345"
    end
  end

  describe ".client_class_for" do
    it "returns the registered client class for a known source" do
      expect(described_class.client_class_for("royalroad")).to eq PeasantPath::RoyalRoadClient
    end

    it "raises for an unknown source" do
      expect { described_class.client_class_for("nope") }.to raise_error(ArgumentError, /nope/)
    end
  end

  describe ".source_key_for_host" do
    it "finds the source key registered for a known host" do
      expect(described_class.source_key_for_host("www.royalroad.com")).to eq "royalroad"
    end

    it "finds the second registered source too" do
      expect(described_class.source_key_for_host("www.fanfiction.net")).to eq "fanfictionnet"
    end

    it "returns nil for an unrecognized host" do
      expect(described_class.source_key_for_host("example.com")).to be_nil
    end
  end

  describe ".chapter_ids_from_url" do
    it "matches against the first registered client that recognizes the URL" do
      result = described_class.chapter_ids_from_url("https://www.royalroad.com/fiction/107917/sky-pride/chapter/2113501/chapter-1")
      expect(result).to eq ["royalroad", "107917", "2113501"]
    end

    it "matches a second source's chapter URL shape too" do
      result = described_class.chapter_ids_from_url("https://www.fanfiction.net/s/8872491/2/Test-Story-Alpha")
      expect(result).to eq ["fanfictionnet", "8872491", "2"]
    end

    it "returns nil for a URL no registered client recognizes" do
      expect(described_class.chapter_ids_from_url("https://example.com/not-a-chapter")).to be_nil
    end
  end

  describe ".scoped_fic_id" do
    it "leaves the default source's fic_id unprefixed" do
      expect(described_class.scoped_fic_id("royalroad", "107917")).to eq "107917"
    end

    it "prefixes a non-default source's fic_id" do
      expect(described_class.scoped_fic_id("othersource", "12345")).to eq "othersource:12345"
    end
  end

  describe ".default_clients" do
    it "returns a client instance for every registered source" do
      clients = described_class.default_clients

      expect(clients.keys).to contain_exactly(*described_class::REGISTRY.keys)
      expect(clients["royalroad"]).to be_a(PeasantPath::RoyalRoadClient)
      expect(clients["fanfictionnet"]).to be_a(PeasantPath::FanFictionNetClient)
    end
  end

  describe ".uri_for" do
    it "builds the canonical story URI for an unprefixed fic_id" do
      expect(described_class.uri_for("107917")).to eq "https://www.royalroad.com/fiction/107917/"
    end

    it "builds the canonical story URI for a scoped fic_id" do
      expect(described_class.uri_for("fanfictionnet:8872491")).to eq "https://www.fanfiction.net/s/8872491/1/"
    end
  end
end
