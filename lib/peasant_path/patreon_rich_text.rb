require "cgi"
require "nokogiri"

module PeasantPath
  # Converts the ProseMirror document Patreon serves in `content_json_string`
  # into the same HTML shape a RoyalRoad `.chapter-content` div has, so the
  # EPUB pipeline (blank-<p> stripping, to_xhtml) needs no source-specific
  # branches.
  #
  # Conversion does not raise for an unexpected node type: a single odd post
  # must not fail a whole pull. Unknown nodes degrade to placeholders or to
  # their children, and each degradation is recorded in `warnings` so the
  # client can log it with the post it came from. (A malformed document, e.g.
  # a non-object where a node should be, still raises: that is corruption,
  # not an unknown feature.)
  class PatreonRichText
    # Marks nest in this order, outermost first, so the output is stable
    # regardless of the order Patreon lists them in.
    MARK_TAGS = {
      "link" => nil, # handled separately: needs the href attribute
      "bold" => "strong",
      "italic" => "em",
      "underline" => "u",
      "strike" => "s",
    }.freeze

    attr_reader :warnings

    def self.to_html(doc, warnings: nil)
      converter = new
      html = converter.to_html(doc)
      warnings&.concat(converter.warnings)
      html
    end

    # True when the HTML has at least one alphanumeric character outside of a
    # placeholder, i.e. there is something for a reader to read.
    def self.text?(html)
      fragment = Nokogiri::HTML.fragment(html.to_s)
      fragment.css("em").each { |em| em.remove if em.text =~ /\A\[.* omitted\]\z/ }
      fragment.text.match?(/[[:alnum:]]/)
    end

    def initialize
      @warnings = []
    end

    def to_html(doc)
      body = children_of(doc).map { |node| render_block(node) }.join
      %(<div class="chapter-content">#{body}</div>)
    end

    private

    def children_of(node)
      Array(node && node["content"]).select { |child| child.is_a?(Hash) }
    end

    # Block nodes seen in real collections beyond paragraphs: section headings,
    # scene-break rules, and the occasional list. Rendered as the obvious HTML
    # so they survive into the EPUB instead of becoming placeholders.
    def render_block(node)
      case node["type"]
      when "paragraph"
        render_paragraph(node)
      when "heading"
        level = node.dig("attrs", "level").to_i
        tag = level.between?(1, 6) ? "h#{[level + 2, 6].min}" : "h3"
        "<#{tag}>#{children_of(node).map { |child| render_inline(child) }.join}</#{tag}>"
      when "horizontalRule"
        "<hr/>"
      when "bulletList", "orderedList"
        tag = node["type"] == "bulletList" ? "ul" : "ol"
        "<#{tag}>#{children_of(node).map { |child| render_list_item(child) }.join}</#{tag}>"
      when "blockquote"
        "<blockquote>#{children_of(node).map { |child| render_block(child) }.join}</blockquote>"
      when "text", "hardBreak"
        # Inline content directly under the doc (or under an unknown block):
        # wrap it so it still shows up as a paragraph.
        "<p>#{render_inline(node)}</p>"
      else
        if children_of(node).empty?
          @warnings << "#{node["type"]} node omitted"
          "<p><em>[#{escape(node["type"])} omitted]</em></p>"
        else
          @warnings << "#{node["type"]} node flattened"
          render_unknown_container(node)
        end
      end
    end

    def render_paragraph(node)
      inner = children_of(node).map { |child| render_inline(child) }.join
      # Patreon's editor emits empty paragraphs as spacing between paragraphs;
      # RoyalRoad chapters carry no such spacers, and the EPUB CSS already
      # separates paragraphs, so they are dropped rather than rendered.
      return "" if inner.empty?

      align = node.dig("attrs", "nodeTextAlignment")
      align == "center" ? %(<p style="text-align:center">#{inner}</p>) : "<p>#{inner}</p>"
    end

    # Genuinely unknown containers (callouts, mentions, whatever Patreon adds
    # next) lose their structure but keep their text: inline children are
    # grouped into one paragraph, block children are rendered as blocks.
    def render_unknown_container(node)
      inline, blocks = children_of(node).partition { |child| inline?(child) }
      out = +""
      out << "<p>#{inline.map { |child| render_inline(child) }.join}</p>" unless inline.empty?
      out << blocks.map { |child| render_block(child) }.join
      out
    end

    def render_list_item(node)
      return render_block(node) unless node["type"] == "listItem"

      "<li>#{children_of(node).map { |child| render_block(child) }.join}</li>"
    end

    def inline?(node)
      %w[text hardBreak].include?(node["type"])
    end

    def render_inline(node)
      case node["type"]
      when "text"
        wrap_marks(escape(node["text"]), Array(node["marks"]))
      when "hardBreak"
        "<br/>"
      else
        if children_of(node).empty?
          @warnings << "#{node["type"]} node omitted"
          "<em>[#{escape(node["type"])} omitted]</em>"
        else
          @warnings << "#{node["type"]} node flattened"
          children_of(node).map { |child| render_inline(child) }.join
        end
      end
    end

    def wrap_marks(text, marks)
      present = marks.map { |m| m["type"] }
      out = text
      MARK_TAGS.keys.reverse_each do |mark_type|
        next unless present.include?(mark_type)

        if mark_type == "link"
          href = marks.find { |m| m["type"] == "link" }.dig("attrs", "href").to_s
          out = %(<a href="#{escape(href)}">#{out}</a>) unless href.empty?
        else
          tag = MARK_TAGS[mark_type]
          out = "<#{tag}>#{out}</#{tag}>"
        end
      end
      unknown = present - MARK_TAGS.keys
      @warnings << "unknown marks ignored: #{unknown.join(", ")}" unless unknown.empty?
      out
    end

    def escape(text)
      CGI.escapeHTML(text.to_s)
    end
  end
end
