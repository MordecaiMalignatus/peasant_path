require "peasant_road"

RSpec.describe PeasantRoad::Fic do
  let(:mock_repo) { instance_double(PeasantRoad::DiskRepository) }
  let(:mock_rr) { instance_double(PeasantRoad::RoyalRoadClient) }
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
      "previous_chapter" => nil
    }
  end

  let(:old_chapter_2_disk) do
    {
      "fic_id" => fic_id,
      "chapter_uri" => chapter_uri_2,
      "chapter_title" => "Chapter 2- Gourmet in the Garbage",
      "chapter_text" => "<p>Content</p>",
      "next_chapter" => nil,
      "previous_chapter" => "/fiction/107917/sky-pride/chapter/2113501/chapter-1--in-the-care-of-a-hateful-god"
    }
  end

  let(:overview) do
    [
      { "id" => 2113501, "volumeId" => 10395, "order" => 0, "title" => "Chapter 1- In the Care of a Hateful God", "url" => "/fiction/107917/sky-pride/chapter/2113501/chapter-1--in-the-care-of-a-hateful-god" },
      { "id" => 2113560, "volumeId" => 10395, "order" => 1, "title" => "Chapter 2- Gourmet in the Garbage", "url" => "/fiction/107917/sky-pride/chapter/2113560/chapter-2--gourmet-in-the-garbage" }
    ]
  end

  def build_fic_with_chapters(chapters_on_disk)
    allow(mock_repo).to receive(:list_chapters).with(fic_id).and_return(
      chapters_on_disk.map { |c| "/config/#{fic_id}/#{c["chapter_uri"].split("/").last(2).first}" }
    )
    chapters_on_disk.each do |c|
      path = "/config/#{fic_id}/#{c["chapter_uri"].split("/").last(2).first}"
      allow(mock_repo).to receive(:read_chapter_from_path).with(path).and_return(c)
    end

    fic = described_class.new(fic_id: fic_id, repository: mock_repo)
    fic.instance_variable_set(:@rr, mock_rr)
    fic
  end

  describe "#backfill_chapter_volumes!" do
    context "when chapters on disk are missing volume and order data" do
      it "writes updated chapter files with volume_id and order_number" do
        fic = build_fic_with_chapters([old_chapter_1_disk, old_chapter_2_disk])

        allow(mock_rr).to receive(:chapter_overview).with(fic_id).and_return(overview)
        allow(mock_repo).to receive(:read_chapter).with(fic_id, "2113501").and_return(old_chapter_1_disk)
        allow(mock_repo).to receive(:read_chapter).with(fic_id, "2113560").and_return(old_chapter_2_disk)

        expect(mock_repo).to receive(:write_chapter).with(
          fic_id, "2113501",
          include('"volume_id": 10395').and(include('"order_number": 0'))
        )
        expect(mock_repo).to receive(:write_chapter).with(
          fic_id, "2113560",
          include('"volume_id": 10395').and(include('"order_number": 1'))
        )

        fic.backfill_chapter_volumes!
      end

      it "updates the in-memory chapter objects" do
        fic = build_fic_with_chapters([old_chapter_1_disk])

        allow(mock_rr).to receive(:chapter_overview).with(fic_id).and_return(overview)
        allow(mock_repo).to receive(:read_chapter).with(fic_id, "2113501").and_return(old_chapter_1_disk)
        allow(mock_repo).to receive(:write_chapter)

        fic.backfill_chapter_volumes!

        expect(fic.chapters.first.volume_id).to eq 10395
        expect(fic.chapters.first.order_number).to eq 0
      end
    end

    context "when a chapter already has volume and order data" do
      let(:already_backfilled) do
        old_chapter_1_disk.merge("volume_id" => 10395, "order_number" => 0)
      end

      it "does not rewrite the chapter file" do
        fic = build_fic_with_chapters([already_backfilled])

        allow(mock_rr).to receive(:chapter_overview).with(fic_id).and_return(overview)
        allow(mock_repo).to receive(:read_chapter).with(fic_id, "2113501").and_return(already_backfilled)

        expect(mock_repo).not_to receive(:write_chapter)

        fic.backfill_chapter_volumes!
      end
    end

    context "when a chapter is not present in the overview" do
      let(:orphaned_chapter_uri) { "https://www.royalroad.com/fiction/107917/sky-pride/chapter/9999999/orphaned" }
      let(:orphaned_disk) do
        {
          "fic_id" => fic_id,
          "chapter_uri" => orphaned_chapter_uri,
          "chapter_title" => "Orphaned",
          "chapter_text" => "<p>Content</p>",
          "next_chapter" => nil,
          "previous_chapter" => nil
        }
      end

      it "skips the chapter without error" do
        fic = build_fic_with_chapters([orphaned_disk])

        allow(mock_rr).to receive(:chapter_overview).with(fic_id).and_return(overview)
        allow(mock_repo).to receive(:read_chapter).with(fic_id, "9999999").and_return(orphaned_disk)

        expect(mock_repo).not_to receive(:write_chapter)

        expect { fic.backfill_chapter_volumes! }.not_to raise_error
      end
    end

    context "when a chapter has a null volumeId in the overview" do
      let(:overview_with_null_volume) do
        [{ "id" => 2113501, "volumeId" => nil, "order" => 0, "title" => "Announcement", "url" => "/fiction/107917/sky-pride/chapter/2113501/announcement" }]
      end

      it "writes null volume_id to disk, marking the chapter as processed" do
        fic = build_fic_with_chapters([old_chapter_1_disk])

        allow(mock_rr).to receive(:chapter_overview).with(fic_id).and_return(overview_with_null_volume)
        allow(mock_repo).to receive(:read_chapter).with(fic_id, "2113501").and_return(old_chapter_1_disk)

        expect(mock_repo).to receive(:write_chapter).with(
          fic_id, "2113501",
          include('"volume_id": null')
        )

        fic.backfill_chapter_volumes!
      end
    end
  end
end
