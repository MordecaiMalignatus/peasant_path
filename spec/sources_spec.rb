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

    it "returns nil for an unrecognized host" do
      expect(described_class.source_key_for_host("example.com")).to be_nil
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

  describe ".uri_for" do
    it "builds the canonical story URI for an unprefixed fic_id" do
      expect(described_class.uri_for("107917")).to eq "https://www.royalroad.com/fiction/107917/"
    end
  end
end
