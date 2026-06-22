require "peasant_path"

RSpec.describe PeasantPath::Config do
  describe ".from_config_file" do
    it "reads the followed stories" do
      config = described_class.from_config_file("followed_stories" => ["1", "2"])
      expect(config.followed_stories).to eq ["1", "2"]
    end

    it "reads the schema version when present" do
      config = described_class.from_config_file("followed_stories" => [], "schema_version" => 1)
      expect(config.schema_version).to eq 1
    end

    it "defaults to an empty list when the key is absent" do
      expect(described_class.from_config_file({}).followed_stories).to eq []
    end

    it "ignores unknown keys rather than raising" do
      expect {
        described_class.from_config_file("followed_stories" => ["1"], "some_future_setting" => true)
      }.not_to raise_error
    end
  end

  describe "#to_json" do
    it "writes the current schema version" do
      expect(JSON.parse(described_class.new.to_json)["schema_version"]).to eq described_class::SCHEMA_VERSION
    end
  end
end
