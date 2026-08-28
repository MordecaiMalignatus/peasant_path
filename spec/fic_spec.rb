require "peasant_path"

RSpec.describe PeasantPath::Fic do
  let(:mock_repo) { instance_double(PeasantPath::DiskRepository) }
  let(:fic_id) { "107917" }

  let(:chapter_uri_1) { "https://www.royalroad.com/fiction/107917/sky-pride/chapter/2113501/chapter-1--in-the-care-of-a-hateful-god" }
  let(:chapter_uri_2) { "https://www.royalroad.com/fiction/107917/sky-pride/chapter/2113560/chapter-2--gourmet-in-the-garbage" }

  let(:old_chapter_1_disk) do
    {
      "fic_id" => fic_id,
      "chapter_uri" => chapter_uri_1,
      "chapter_title" => "Chapter 1- In the Care of a Hateful God",
      "chapter_text" => "<p>Content</p>",
      "next_chapter" => "/fiction/107917/sky-pride/chapter/2113560/chapter-2--gourmet-in-the-garbage",
      "previous_chapter" => nil,
    }
  end

  let(:old_chapter_2_disk) do
    {
      "fic_id" => fic_id,
      "chapter_uri" => chapter_uri_2,
      "chapter_title" => "Chapter 2- Gourmet in the Garbage",
      "chapter_text" => "<p>Content</p>",
      "next_chapter" => nil,
      "previous_chapter" => "/fiction/107917/sky-pride/chapter/2113501/chapter-1--in-the-care-of-a-hateful-god",
    }
  end

  describe ".from_disk" do
    it "loads persisted metadata" do
      allow(mock_repo).to receive(:read_fic_info).with(fic_id).and_return(
        "author" => "Author",
        "title" => "Sky Pride",
        "description" => "A story",
        "display_name" => "My Sky Pride",
        "stats" => { "word_count_estimate" => 123, "chapter_count" => 2, "updated_at" => "2026-06-22T12:34:56Z" },
        "volumes" => [{ "id" => 1, "title" => "Vol 1" }],
      )

      fic = described_class.from_disk(fic_id, mock_repo)

      expect(fic.author).to eq "Author"
      expect(fic.title).to eq "Sky Pride"
      expect(fic.description).to eq "A story"
      expect(fic.display_name).to eq "My Sky Pride"
      expect(fic.volumes).to eq [{ "id" => 1, "title" => "Vol 1" }]
      expect(fic.stats["word_count_estimate"]).to eq 123
    end

    it "loads metadata without stats cleanly" do
      allow(mock_repo).to receive(:read_fic_info).with(fic_id).and_return(
        "author" => "Author",
        "title" => "Sky Pride",
        "volumes" => [],
      )

      fic = described_class.from_disk(fic_id, mock_repo)

      expect(fic.stats).to be_nil
      expect(fic.word_count_estimate).to be_nil
    end

    it "raises a clear error when metadata is missing" do
      allow(mock_repo).to receive(:read_fic_info).with(fic_id).and_raise(Errno::ENOENT)

      expect { described_class.from_disk(fic_id, mock_repo) }.to raise_error(described_class::MissingState, /#{fic_id}/)
    end
  end

  describe "#chapters" do
    it "loads chapters lazily from disk" do
      path = "/config/#{fic_id}/2113501"
      allow(mock_repo).to receive(:list_chapters).with(fic_id).and_return([path])
      allow(mock_repo).to receive(:read_chapter_from_path).with(path).and_return(old_chapter_1_disk)

      fic = described_class.new(fic_id: fic_id, repository: mock_repo)

      expect(mock_repo).not_to have_received(:list_chapters)
      expect(fic.chapters.map(&:chapter_id)).to eq ["2113501"]
      expect(fic.chapters.map(&:chapter_id)).to eq ["2113501"]
      expect(mock_repo).to have_received(:list_chapters).once
    end

    it "sorts chapters by order number, falling back to chapter id" do
      path_1 = "/config/#{fic_id}/2113501"
      path_2 = "/config/#{fic_id}/2113560"
      chapter_1 = old_chapter_1_disk.merge("order_number" => 1)
      chapter_2 = old_chapter_2_disk.merge("order_number" => 0)
      allow(mock_repo).to receive(:list_chapters).with(fic_id).and_return([path_1, path_2])
      allow(mock_repo).to receive(:read_chapter_from_path).with(path_1).and_return(chapter_1)
      allow(mock_repo).to receive(:read_chapter_from_path).with(path_2).and_return(chapter_2)

      fic = described_class.new(fic_id: fic_id, repository: mock_repo)

      expect(fic.chapters.map(&:chapter_id)).to eq ["2113560", "2113501"]
    end
  end

  describe "#source" do
    it "treats an unprefixed fic_id as royalroad" do
      fic = described_class.new(fic_id: fic_id, repository: mock_repo)

      expect(fic.source).to eq "royalroad"
    end
  end

  describe "#display_title" do
    it "prefers display_name over title" do
      fic = described_class.new(fic_id: fic_id, repository: mock_repo)
      fic.title = "Sky Pride"
      fic.display_name = "My Sky Pride"

      expect(fic.display_title).to eq "My Sky Pride"
    end
  end

  describe "#word_count_estimate" do
    it "reads persisted fic-level stats" do
      fic = described_class.new(fic_id: fic_id, repository: mock_repo)
      fic.stats = { "word_count_estimate" => 5 }

      expect(fic.word_count_estimate).to eq 5
    end
  end

  describe "#refresh_stats!" do
    it "writes fic-level totals" do
      path_1 = "/config/#{fic_id}/2113501"
      path_2 = "/config/#{fic_id}/2113560"
      allow(mock_repo).to receive(:list_chapters).with(fic_id).and_return([path_1, path_2])
      allow(mock_repo).to receive(:read_chapter_from_path).with(path_1).and_return(old_chapter_1_disk.merge("chapter_text" => "<p>One two, three.</p>", "volume_id" => 10395, "order_number" => 0))
      allow(mock_repo).to receive(:read_chapter_from_path).with(path_2).and_return(old_chapter_2_disk.merge("chapter_text" => "<p>Four-five six's</p>", "volume_id" => 10395, "order_number" => 1))
      allow(mock_repo).to receive(:write_fic_info_hash)

      fic = described_class.new(fic_id: fic_id, repository: mock_repo)
      fic.title = "Sky Pride"
      fic.volumes = [{ "id" => 10395, "title" => "Volume 1" }]
      fic.refresh_stats!

      expect(mock_repo).to have_received(:write_fic_info_hash).with(fic_id, hash_including(stats: hash_including("word_count_estimate" => 6, "chapter_count" => 2, "updated_at" => kind_of(String))))
    end

    it "writes per-volume chapter_count, chapter_ids, and word_count_estimate" do
      path_1 = "/config/#{fic_id}/2113501"
      path_2 = "/config/#{fic_id}/2113560"
      allow(mock_repo).to receive(:list_chapters).with(fic_id).and_return([path_1, path_2])
      allow(mock_repo).to receive(:read_chapter_from_path).with(path_1).and_return(old_chapter_1_disk.merge("chapter_text" => "<p>One two three.</p>", "volume_id" => 10395, "order_number" => 0))
      allow(mock_repo).to receive(:read_chapter_from_path).with(path_2).and_return(old_chapter_2_disk.merge("chapter_text" => "<p>Four five.</p>", "volume_id" => 10397, "order_number" => 1))
      allow(mock_repo).to receive(:write_fic_info_hash)

      fic = described_class.new(fic_id: fic_id, repository: mock_repo)
      fic.volumes = [{ "id" => 10395, "title" => "Volume 1" }, { "id" => 10397, "title" => "Volume 2" }]
      fic.refresh_stats!

      expect(fic.volumes).to eq([
        { "id" => 10395, "title" => "Volume 1", "word_count_estimate" => 3, "chapter_count" => 1, "chapter_ids" => ["2113501"] },
        { "id" => 10397, "title" => "Volume 2", "word_count_estimate" => 2, "chapter_count" => 1, "chapter_ids" => ["2113560"] },
      ])
    end
  end
end
