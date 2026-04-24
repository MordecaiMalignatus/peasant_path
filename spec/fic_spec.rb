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
end
