require "peasant_path"

RSpec.describe PeasantPath::WordCounter do
  describe ".count_html" do
    it "strips HTML, scripts, and styles before counting" do
      html = "<p>One <strong>two</strong>.</p><script>ignored()</script><style>.ignored { color: red; }</style>"

      expect(described_class.count_html(html)).to eq 2
    end
  end

  describe ".count_text" do
    it "uses ICU word boundaries for contractions and hyphenated compounds" do
      expect(described_class.count_text("One two-three four's can't stop.")).to eq 6
    end

    it "counts numeric word segments" do
      expect(described_class.count_text("Chapter 12 has 3 scenes.")).to eq 5
    end

    it "handles non-ASCII letters" do
      expect(described_class.count_text("Café mañana naïve.")).to eq 3
    end
  end
end
