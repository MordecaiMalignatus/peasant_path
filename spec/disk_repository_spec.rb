require "peasant_road"
require "tmpdir"

RSpec.describe PeasantRoad::DiskRepository do
  let(:tmpdir) { Dir.mktmpdir }
  let(:repo) { described_class.new(tmpdir) }
  let(:fic_id) { "107917" }

  after { FileUtils.rm_rf(tmpdir) }

  describe "#write_volume_cover_image and #read_volume_cover_image" do
    it "round-trips volume cover image data" do
      repo.write_volume_cover_image(fic_id, 10395, "fake_image_data")
      expect(repo.read_volume_cover_image(fic_id, 10395)).to eq "fake_image_data"
    end

    it "stores covers at a path that includes the volume ID" do
      repo.write_volume_cover_image(fic_id, 10395, "data")
      expect(repo.volume_cover_image_path(fic_id, 10395)).to include("10395")
    end

    it "stores covers for different volumes at distinct paths" do
      expect(repo.volume_cover_image_path(fic_id, 10395)).not_to eq(
        repo.volume_cover_image_path(fic_id, 10397)
      )
    end
  end

  describe "#list_chapters" do
    before do
      FileUtils.mkdir_p("#{tmpdir}/#{fic_id}")
      File.write("#{tmpdir}/#{fic_id}/fic_info.json", "{}")
      File.write("#{tmpdir}/#{fic_id}/cover_image.jpg", "fic_cover")
      File.write("#{tmpdir}/#{fic_id}/volume_10395_cover.jpg", "vol1_cover")
      File.write("#{tmpdir}/#{fic_id}/volume_10397_cover.jpg", "vol2_cover")
      File.write("#{tmpdir}/#{fic_id}/2113501", "{}")
      File.write("#{tmpdir}/#{fic_id}/2113560", "{}")
    end

    it "excludes fic_info.json" do
      expect(repo.list_chapters(fic_id)).not_to include("#{tmpdir}/#{fic_id}/fic_info.json")
    end

    it "excludes the fic cover image" do
      expect(repo.list_chapters(fic_id)).not_to include("#{tmpdir}/#{fic_id}/cover_image.jpg")
    end

    it "excludes volume cover images" do
      result = repo.list_chapters(fic_id)
      expect(result).not_to include("#{tmpdir}/#{fic_id}/volume_10395_cover.jpg")
      expect(result).not_to include("#{tmpdir}/#{fic_id}/volume_10397_cover.jpg")
    end

    it "includes chapter files" do
      result = repo.list_chapters(fic_id)
      expect(result).to include("#{tmpdir}/#{fic_id}/2113501")
      expect(result).to include("#{tmpdir}/#{fic_id}/2113560")
    end
  end
end
