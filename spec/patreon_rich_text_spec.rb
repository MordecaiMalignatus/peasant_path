require "peasant_path"
require "peasant_path/patreon_rich_text"

RSpec.describe PeasantPath::PatreonRichText do
  def doc(*blocks)
    { "type" => "doc", "content" => blocks }
  end

  def para(*inline, align: nil)
    node = { "type" => "paragraph", "content" => inline }
    node["attrs"] = { "nodeTextAlignment" => align } if align
    node
  end

  def text(str, *marks)
    node = { "type" => "text", "text" => str }
    node["marks"] = marks.map { |m| m.is_a?(Hash) ? m : { "type" => m } } unless marks.empty?
    node
  end

  describe ".to_html" do
    it "wraps the body in a chapter-content div like RoyalRoad" do
      expect(described_class.to_html(doc(para(text("Hi."))))).to eq %(<div class="chapter-content"><p>Hi.</p></div>)
    end

    it "centres epigraph paragraphs" do
      html = described_class.to_html(doc(para(text("Every Heaven is balanced by a Hell.", "italic"), align: "center")))
      expect(html).to include %(<p style="text-align:center"><em>Every Heaven is balanced by a Hell.</em></p>)
    end

    it "drops empty paragraphs, which Patreon's editor emits as spacing" do
      expect(described_class.to_html(doc(para, para(text("Kept."))))).to eq %(<div class="chapter-content"><p>Kept.</p></div>)
    end

    it "ignores non-object entries in a content array without raising" do
      broken = { "type" => "doc", "content" => [nil, "stray", para(nil, text("ok"))] }
      expect(described_class.to_html(broken)).to eq %(<div class="chapter-content"><p>ok</p></div>)
    end

    it "escapes text" do
      expect(described_class.to_html(doc(para(text("a < b & \"c\""))))).to include "a &lt; b &amp; &quot;c&quot;"
    end

    it "applies marks in a fixed order regardless of input order" do
      a = described_class.to_html(doc(para(text("x", "italic", "bold"))))
      b = described_class.to_html(doc(para(text("x", "bold", "italic"))))
      expect(a).to eq b
      expect(a).to include "<strong><em>x</em></strong>"
    end

    it "supports underline, strike and link marks" do
      html = described_class.to_html(doc(para(text("u", "underline"), text("s", "strike"), text("l", { "type" => "link", "attrs" => { "href" => "https://example.com/?a=1&b=2" } }))))
      expect(html).to include "<u>u</u>"
      expect(html).to include "<s>s</s>"
      expect(html).to include %(<a href="https://example.com/?a=1&amp;b=2">l</a>)
    end

    it "renders hard breaks" do
      expect(described_class.to_html(doc(para(text("a"), { "type" => "hardBreak" }, text("b"))))).to include "a<br/>b"
    end

    it "replaces non-text nodes with a placeholder and records a warning" do
      warnings = []
      html = described_class.to_html(doc({ "type" => "image", "attrs" => { "src" => "x" } }), warnings: warnings)
      expect(html).to include "<p><em>[image omitted]</em></p>"
      expect(warnings).to include "image node omitted"
    end

    it "flattens genuinely unknown containers to their text and warns" do
      warnings = []
      callout = { "type" => "callout", "content" => [para(text("Noted."))] }
      span = { "type" => "mention", "content" => [text("Someone")] }
      html = described_class.to_html(doc(callout, span), warnings: warnings)
      expect(html).to include "<p>Noted.</p>"
      expect(html).to include "<p>Someone</p>"
      expect(warnings).to include "callout node flattened"
      expect(warnings).to include "mention node flattened"
    end

    it "never raises on malformed nodes" do
      expect { described_class.to_html(doc({ "type" => "mystery" }, { "type" => "paragraph" }, {})) }.not_to raise_error
    end
  end

  describe ".text?" do
    it "is true when there is readable text" do
      expect(described_class.text?(%(<div class="chapter-content"><p>Hello.</p></div>))).to be true
    end

    it "is false for placeholders only" do
      expect(described_class.text?(%(<div class="chapter-content"><p><em>[image omitted]</em></p><p> </p></div>))).to be false
    end
  end
end

RSpec.describe PeasantPath::PatreonRichText, "block nodes seen in real feeds" do
  def para(text)
    { "type" => "paragraph", "content" => [{ "type" => "text", "text" => text }] }
  end

  it "renders headings, rules, lists and blockquotes as HTML without warnings" do
    warnings = []
    doc = { "type" => "doc", "content" => [
      { "type" => "heading", "attrs" => { "level" => 1 }, "content" => [{ "type" => "text", "text" => "Book 8 End" }] },
      { "type" => "horizontalRule" },
      { "type" => "bulletList", "content" => [{ "type" => "listItem", "content" => [para("one")] }, { "type" => "listItem", "content" => [para("two")] }] },
      { "type" => "orderedList", "content" => [{ "type" => "listItem", "content" => [para("first")] }] },
      { "type" => "blockquote", "content" => [para("quoted")] },
    ] }

    html = described_class.to_html(doc, warnings: warnings)

    expect(html).to eq '<div class="chapter-content"><h3>Book 8 End</h3><hr/><ul><li><p>one</p></li><li><p>two</p></li></ul><ol><li><p>first</p></li></ol><blockquote><p>quoted</p></blockquote></div>'
    expect(warnings).to be_empty
  end

  it "clamps heading levels so chapter headings stay below the EPUB's h2 title" do
    doc = { "type" => "doc", "content" => [{ "type" => "heading", "attrs" => { "level" => 5 }, "content" => [{ "type" => "text", "text" => "x" }] }] }
    expect(described_class.to_html(doc)).to include("<h6>x</h6>")
  end
end
