require "peasant_road"

RSpec.describe PeasantRoad::Epub do
  let(:mock_repo) { instance_double(PeasantRoad::DiskRepository) }
  let(:fic_cover_path) { "/config/107917/cover_image.jpg" }
  let(:mock_fic) do
    instance_double(
      PeasantRoad::Fic,
      fic_id: "107917",
      display_title: "Sky Pride",
      author: "Warby Picus",
      repository: mock_repo,
      chapters: [],
      volumes: []
    )
  end
  let(:mock_book) { double("GEPUB::Book", generate_epub: nil) }

  before do
    allow(mock_repo).to receive(:cover_image_path).with("107917").and_return(fic_cover_path)
  end

  def make_chapters(count, volume_id:)
    Array.new(count) { instance_double(PeasantRoad::Chapter, volume_id: volume_id, chapter_title: "Ch") }
  end

  def make_volume(id:, title:)
    { "id" => id, "title" => title }
  end

  describe "#build" do
    it "compiles an epub with the fic title, author, and cover" do
      epub = described_class.new(mock_fic)
      allow(described_class).to receive(:compile).and_return(mock_book)

      epub.build("Sky Pride.epub")

      expect(described_class).to have_received(:compile).with(
        title: "Sky Pride",
        author: "Warby Picus",
        cover_path: fic_cover_path,
        chapters: [],
        identifier: "https://www.royalroad.com/fiction/107917/"
      )
    end

    it "generates the epub at the given path" do
      epub = described_class.new(mock_fic)
      allow(described_class).to receive(:compile).and_return(mock_book)

      epub.build("Sky Pride.epub")

      expect(mock_book).to have_received(:generate_epub).with("Sky Pride.epub")
    end
  end

  describe "#build_volumes" do
    context "when a volume has fewer than 10 chapters" do
      it "skips the volume" do
        allow(mock_fic).to receive(:chapters).and_return(make_chapters(9, volume_id: 1))
        allow(mock_fic).to receive(:volumes).and_return([make_volume(id: 1, title: "Vol 1")])
        allow(mock_repo).to receive(:volume_cover_image_path).with("107917", 1).and_return("/no.jpg")
        allow(File).to receive(:exist?).with("/no.jpg").and_return(false)

        epub = described_class.new(mock_fic)
        allow(described_class).to receive(:compile)

        epub.build_volumes

        expect(described_class).not_to have_received(:compile)
      end
    end

    context "when a volume has exactly 10 chapters" do
      it "builds an epub for that volume" do
        allow(mock_fic).to receive(:chapters).and_return(make_chapters(10, volume_id: 1))
        allow(mock_fic).to receive(:volumes).and_return([make_volume(id: 1, title: "Vol 1")])
        allow(mock_repo).to receive(:volume_cover_image_path).with("107917", 1).and_return("/no.jpg")
        allow(File).to receive(:exist?).with("/no.jpg").and_return(false)

        epub = described_class.new(mock_fic)
        allow(described_class).to receive(:compile).and_return(mock_book)

        epub.build_volumes

        expect(described_class).to have_received(:compile)
        expect(mock_book).to have_received(:generate_epub).with("Sky Pride - Vol 1.epub")
      end
    end

    context "when a volume cover exists on disk" do
      it "uses the volume cover" do
        vol_cover_path = "/config/107917/volume_1_cover.jpg"
        allow(mock_fic).to receive(:chapters).and_return(make_chapters(10, volume_id: 1))
        allow(mock_fic).to receive(:volumes).and_return([make_volume(id: 1, title: "Vol 1")])
        allow(mock_repo).to receive(:volume_cover_image_path).with("107917", 1).and_return(vol_cover_path)
        allow(File).to receive(:exist?).with(vol_cover_path).and_return(true)

        epub = described_class.new(mock_fic)
        allow(described_class).to receive(:compile).and_return(mock_book)

        epub.build_volumes

        expect(described_class).to have_received(:compile).with(hash_including(cover_path: vol_cover_path))
      end
    end

    context "when a volume cover does not exist on disk" do
      it "falls back to the fic cover" do
        allow(mock_fic).to receive(:chapters).and_return(make_chapters(10, volume_id: 1))
        allow(mock_fic).to receive(:volumes).and_return([make_volume(id: 1, title: "Vol 1")])
        allow(mock_repo).to receive(:volume_cover_image_path).with("107917", 1).and_return("/no.jpg")
        allow(File).to receive(:exist?).with("/no.jpg").and_return(false)

        epub = described_class.new(mock_fic)
        allow(described_class).to receive(:compile).and_return(mock_book)

        epub.build_volumes

        expect(described_class).to have_received(:compile).with(hash_including(cover_path: fic_cover_path))
      end
    end

    it "uses the combined fic and volume title" do
      allow(mock_fic).to receive(:chapters).and_return(make_chapters(10, volume_id: 1))
      allow(mock_fic).to receive(:volumes).and_return([make_volume(id: 1, title: "The Feral Daoist")])
      allow(mock_repo).to receive(:volume_cover_image_path).with("107917", 1).and_return("/no.jpg")
      allow(File).to receive(:exist?).with("/no.jpg").and_return(false)

      epub = described_class.new(mock_fic)
      allow(described_class).to receive(:compile).and_return(mock_book)

      epub.build_volumes

      expect(described_class).to have_received(:compile).with(
        hash_including(title: "Sky Pride - The Feral Daoist")
      )
    end

    it "only passes chapters belonging to the volume" do
      vol1_chapters = make_chapters(10, volume_id: 1)
      vol2_chapters = make_chapters(3, volume_id: 2)
      allow(mock_fic).to receive(:chapters).and_return(vol1_chapters + vol2_chapters)
      allow(mock_fic).to receive(:volumes).and_return([make_volume(id: 1, title: "Vol 1")])
      allow(mock_repo).to receive(:volume_cover_image_path).with("107917", 1).and_return("/no.jpg")
      allow(File).to receive(:exist?).with("/no.jpg").and_return(false)

      epub = described_class.new(mock_fic)
      allow(described_class).to receive(:compile).and_return(mock_book)

      epub.build_volumes

      expect(described_class).to have_received(:compile).with(
        hash_including(chapters: vol1_chapters)
      )
    end
  end

  describe "#build_all" do
    it "builds the combined epub and volume epubs" do
      epub = described_class.new(mock_fic)
      allow(epub).to receive(:build)
      allow(epub).to receive(:build_volumes)

      epub.build_all("Sky Pride.epub")

      expect(epub).to have_received(:build).with("Sky Pride.epub")
      expect(epub).to have_received(:build_volumes)
    end
  end
end
