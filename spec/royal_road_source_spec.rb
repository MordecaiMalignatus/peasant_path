require "peasant_path"

RSpec.describe PeasantPath::RoyalRoadSource do
  let(:client) { instance_double(PeasantPath::RoyalRoadClient) }
  let(:repo) { instance_double(PeasantPath::DiskRepository) }
  let(:fic) { PeasantPath::Fic.new(fic_id: "107917", repository: repo) }
  let(:source) { described_class.new(client) }

  def toc(*ids)
    ids.each_with_index.map do |id, i|
      { "id" => id, "volumeId" => 1, "order" => i, "title" => "Chapter #{id}", "url" => "/fiction/107917/sky-pride/chapter/#{id}/chapter-#{id}" }
    end
  end

  def teasers(ids, known_ids:)
    allow(client).to receive(:chapter_overview).with("107917").and_return(toc(*ids))
    source.chapter_overview(fic, known_ids: known_ids).select(&:teaser?).map(&:chapter_id)
  end

  describe "#chapter_overview" do
    it "marks nothing on a story's first pull" do
      expect(teasers([9000, 5080, 5081], known_ids: [])).to be_empty
    end

    it "marks nothing when new chapters come after the ones already pulled" do
      expect(teasers([5080, 5081, 5200, 5201], known_ids: %w[5080 5081])).to be_empty
    end

    it "marks a new chapter listed ahead of chapters already pulled as a teaser" do
      expect(teasers([5150, 5080, 5081, 5200], known_ids: %w[5000 5079 5080 5081])).to eq ["5150"]
    end

    it "marks a teaser that sits between chapters already pulled" do
      expect(teasers([5000, 5150, 5080, 5200], known_ids: %w[5000 5080])).to eq ["5150"]
    end

    it "does not mark a chapter that comes back after being hidden" do
      expect(teasers([5079, 5080, 5081], known_ids: %w[5080 5081])).to be_empty
    end

    it "never marks a chapter already pulled" do
      expect(teasers([5080, 5000], known_ids: %w[5000 5080])).to be_empty
    end
  end
end
