require "peasant_path"

RSpec.describe PeasantPath::Sources do
  describe ".resolve" do
    it "resolves a RoyalRoad fiction URL to the numeric fic id" do
      result = described_class.resolve("https://www.royalroad.com/fiction/107917/sky-pride")

      expect(result).to eq(source: "royalroad", fic_id: "107917", uri: "https://www.royalroad.com/fiction/107917/", source_ref: {})
    end

    it "resolves a Patreon collection URL, ignoring the query string" do
      result = described_class.resolve("https://www.patreon.com/collection/1522125?view=expanded")

      expect(result).to eq(
        source: "patreon",
        fic_id: "patreon-col-1522125",
        uri: "https://www.patreon.com/collection/1522125",
        source_ref: { "collection_id" => "1522125" },
      )
    end

    %w[
      https://www.patreon.com/u84402213
      https://www.patreon.com/u84402213/posts
      https://www.patreon.com/c/u84402213
      https://www.patreon.com/cw/u84402213/
    ].each do |url|
      it "resolves the creator URL #{url} to a vanity-based provisional id" do
        result = described_class.resolve(url)

        expect(result).to eq(
          source: "patreon",
          fic_id: "patreon-v-u84402213",
          uri: "https://www.patreon.com/u84402213/posts",
          source_ref: { "vanity" => "u84402213" },
        )
      end
    end

    it "accepts RoyalRoad URLs without www or a trailing slash" do
      expect(described_class.resolve("https://royalroad.com/fiction/123")[:fic_id]).to eq "123"
      expect(described_class.resolve("http://www.royalroad.com/fiction/123")[:uri]).to eq "https://www.royalroad.com/fiction/123/"
    end

    it "rejects non-http schemes" do
      expect { described_class.resolve("ftp://www.royalroad.com/fiction/1/") }.to raise_error(PeasantPath::Library::InvalidURL)
    end

    it "maps the legacy /user?u=<id> creator link onto the numeric vanity" do
      expect(described_class.resolve("https://www.patreon.com/user?u=84402213")).to include(fic_id: "patreon-v-u84402213", source_ref: { "vanity" => "u84402213" })
    end

    it "rejects /user without a numeric id" do
      expect { described_class.resolve("https://www.patreon.com/user") }.to raise_error(PeasantPath::Library::InvalidURL)
      expect { described_class.resolve("https://www.patreon.com/user?u=abc") }.to raise_error(PeasantPath::Library::InvalidURL)
    end

    it "treats vanities case-insensitively so one creator gets one directory" do
      expect(described_class.resolve("https://www.patreon.com/Foo")[:fic_id]).to eq "patreon-v-foo"
      expect(described_class.resolve("https://www.patreon.com/foo")[:fic_id]).to eq "patreon-v-foo"
    end

    it "rejects Patreon pages that are not creators or collections" do
      expect { described_class.resolve("https://www.patreon.com/login") }.to raise_error(PeasantPath::Library::InvalidURL)
      expect { described_class.resolve("https://www.patreon.com/posts/some-post-123") }.to raise_error(PeasantPath::Library::InvalidURL)
    end

    it "rejects a RoyalRoad URL without a fiction path" do
      expect { described_class.resolve("https://www.royalroad.com/") }.to raise_error(PeasantPath::Library::InvalidURL, /not a RoyalRoad story URL/)
    end

    it "rejects other hosts and malformed URLs with InvalidURL" do
      expect { described_class.resolve("https://example.com/fiction/1/") }.to raise_error(PeasantPath::Library::InvalidURL, /not a RoyalRoad or Patreon URL/)
      expect { described_class.resolve("http://[bad") }.to raise_error(PeasantPath::Library::InvalidURL, /not a valid URL/)
    end
  end
end
