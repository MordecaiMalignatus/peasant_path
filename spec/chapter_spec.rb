require "peasant_path"

RSpec.describe PeasantPath::Chapter do
  let(:mock_repo) { double("DiskRepository") }
  let(:chapter_uri) { "https://www.royalroad.com/fiction/107917/sky-pride/chapter/2113501/chapter-1--in-the-care-of-a-hateful-god" }

  describe "#initialize" do
    it "raises a clear error for invalid chapter URLs" do
      expect {
        described_class.new("https://example.com/not-a-chapter", mock_repo)
      }.to raise_error(described_class::InvalidURL, /Invalid RoyalRoad chapter URL/)
    end
  end

  describe ".from_disk_content" do
    let(:new_format_content) do
      {
        "chapter_uri" => chapter_uri,
        "chapter_title" => "Chapter 1- In the Care of a Hateful God",
        "chapter_text" => "<p>Content</p>",
        "next_chapter" => "/fiction/107917/sky-pride/chapter/2113560/chapter-2--gourmet-in-the-garbage",
        "previous_chapter" => nil,
        "volume_id" => 10395,
        "order_number" => 0,
      }
    end

    let(:old_format_content) do
      {
        "chapter_uri" => chapter_uri,
        "chapter_title" => "Chapter 1- In the Care of a Hateful God",
        "chapter_text" => "<p>Content</p>",
        "next_chapter" => "/fiction/107917/sky-pride/chapter/2113560/chapter-2--gourmet-in-the-garbage",
        "previous_chapter" => nil,
      }
    end

    context "with new format (volume_id and order_number present)" do
      it "parses volume_id" do
        result = described_class.from_disk_content(new_format_content, mock_repo)
        expect(result.volume_id).to eq 10395
      end

      it "parses order_number" do
        result = described_class.from_disk_content(new_format_content, mock_repo)
        expect(result.order_number).to eq 0
      end

      it "loads persisted word_count_estimate" do
        result = described_class.from_disk_content(new_format_content.merge("word_count_estimate" => 123), mock_repo)
        expect(result.word_count_estimate).to eq 123
      end
    end

    context "with old format (volume_id and order_number absent)" do
      it "parses without error" do
        expect { described_class.from_disk_content(old_format_content, mock_repo) }.not_to raise_error
      end

      it "sets volume_id to nil" do
        result = described_class.from_disk_content(old_format_content, mock_repo)
        expect(result.volume_id).to be_nil
      end

      it "sets order_number to nil" do
        result = described_class.from_disk_content(old_format_content, mock_repo)
        expect(result.order_number).to be_nil
      end

      it "still parses core fields correctly" do
        result = described_class.from_disk_content(old_format_content, mock_repo)
        expect(result.chapter_title).to eq "Chapter 1- In the Care of a Hateful God"
        expect(result.chapter_text).to eq "<p>Content</p>"
        expect(result.fic_id).to eq "107917"
        expect(result.chapter_id).to eq "2113501"
      end
    end
  end

  describe "#word_count_estimate" do
    it "uses the shared word counter" do
      chapter = described_class.new(chapter_uri, mock_repo)
      chapter.chapter_text = "<p>One <strong>two-three</strong> four's.</p><script>ignored()</script>"
      allow(PeasantPath::WordCounter).to receive(:count_html).with(chapter.chapter_text).and_return(3)

      expect(chapter.word_count_estimate).to eq 3
    end
  end

  describe "#persist" do
    it "includes word_count_estimate in chapter JSON" do
      chapter = described_class.new(chapter_uri, mock_repo)
      chapter.chapter_title = "Chapter 1"
      chapter.chapter_text = "<p>One two three.</p>"
      allow(mock_repo).to receive(:chapter_exists?).with("107917", "2113501").and_return(false)
      allow(mock_repo).to receive(:write_chapter_hash)

      chapter.persist

      expect(mock_repo).to have_received(:write_chapter_hash).with("107917", "2113501", hash_including(word_count_estimate: 3))
    end
  end
end

RSpec.describe PeasantPath::Chapter, "with explicit ids (Patreon)" do
  let(:mock_repo) { double("DiskRepository") }
  let(:chapter) do
    described_class.new(
      "https://www.patreon.com/u84402213/posts/ix-34-new-exit-172080149",
      fic_id: "patreon-col-1522125", chapter_id: 172080149, source: "patreon", repository: mock_repo,
    )
  end

  it "takes ids from the arguments instead of the URL" do
    expect(chapter.fic_id).to eq "patreon-col-1522125"
    expect(chapter.chapter_id).to eq "172080149"
    expect(chapter.source).to eq "patreon"
    expect(chapter.repository).to eq mock_repo
  end

  it "uses a source-specific anchor, keeping the RoyalRoad one unchanged" do
    expect(chapter.anchor_id).to eq "pt-ch-172080149"
    rr = described_class.new("https://www.royalroad.com/fiction/107917/sky-pride/chapter/2113501/chapter-1", mock_repo)
    expect(rr.anchor_id).to eq "rr-ch-2113501"
  end

  it "persists and reloads ids, source and published_at" do
    chapter.chapter_title = "IX-34 New Exit"
    chapter.chapter_text = "<p>One two.</p>"
    chapter.published_at = "2026-10-11T19:01:18.000+00:00"
    chapter.order_number = 584
    written = nil
    allow(mock_repo).to receive(:chapter_exists?).and_return(false)
    allow(mock_repo).to receive(:write_chapter_hash) { |_, _, hash| written = hash }

    chapter.persist
    reloaded = described_class.from_disk_content(JSON.parse(JSON.generate(written)), mock_repo)

    expect(written).to include(chapter_id: "172080149", source: "patreon", published_at: "2026-10-11T19:01:18.000+00:00")
    expect(reloaded).to eq chapter
    expect(reloaded.source).to eq "patreon"
    expect(reloaded.anchor_id).to eq "pt-ch-172080149"
    expect(reloaded.published_at).to eq "2026-10-11T19:01:18.000+00:00"
    expect(reloaded.order_number).to eq 584
  end
end
