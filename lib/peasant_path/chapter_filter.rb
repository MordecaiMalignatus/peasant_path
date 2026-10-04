require "nokogiri"
require "crass"

module PeasantPath
  # EPUBs do not retain Royal Road's page stylesheets. Resolve unconditional
  # display rules before removing hidden chapter descendants, so later visible
  # overrides are preserved. Conditional rules and unsupported selectors are
  # skipped; this is intentionally a subset of browser CSS.
  class ChapterFilter
    def remove_hidden_elements!(doc, content)
      elements = content.css("*").to_h { |element| [element, true] }
      display = {}
      doc.css("style").each do |style|
        next unless style["media"].to_s.strip.empty? || style["media"].strip.casecmp?("all")
        next unless style["type"].nil? || style["type"].casecmp?("text/css")
        Crass.parse(style.text).each do |rule|
          next unless rule[:node] == :style_rule
          properties = display_properties(rule[:children])
          next if properties.empty?
          rule[:selector][:tokens].slice_when { |left, _right| left[:node] == :comma }.each do |tokens|
            selector = Crass::Parser.stringify(tokens.reject { |token| token[:node] == :comma }).strip
            begin
              specificity = selector_specificity(Nokogiri::CSS.parse(selector).first)
              next if specificity.nil?
              doc.css(selector).each do |element|
                next unless elements.key?(element)
                apply_display_properties(display, element, properties, [0, *specificity])
              end
            rescue Nokogiri::CSS::SyntaxError
              next
            end
          end
        end
      end
      elements.each_key do |element|
        next unless element["style"]
        properties = display_properties(Crass.parse_properties(element["style"]))
        apply_display_properties(display, element, properties, [1, 0, 0, 0])
      end
      display.each do |element, declaration|
        element.remove if declaration[:hidden]
      end
    end

    private

    def display_properties(nodes)
      nodes.select { |node| node[:node] == :property && node[:name].casecmp?("display") }
    end

    def apply_display_properties(display, element, properties, specificity)
      properties.each do |property|
        priority = [property[:important] ? 1 : 0, *specificity]
        previous = display[element]
        next if previous && (priority <=> previous[:priority]) < 0
        tokens = property[:children].reject { |token| token[:node] == :whitespace }
        hidden = tokens.length == 1 && tokens[0][:node] == :ident && tokens[0][:value].casecmp?("none")
        display[element] = { priority: priority, hidden: hidden }
      end
    end

    def selector_specificity(node)
      return nil unless node.is_a?(Nokogiri::CSS::Node)
      case node.type
      when :ID then [1, 0, 0]
      when :CLASS_CONDITION, :ATTRIBUTE_CONDITION then [0, 1, 0]
      when :ELEMENT_NAME then [0, 0, node.value == ["*"] ? 0 : 1]
      when :CONDITIONAL_SELECTOR, :COMBINATOR, :DESCENDANT_SELECTOR,
           :CHILD_SELECTOR, :DIRECT_ADJACENT_SELECTOR, :FOLLOWING_SELECTOR
        node.value.reduce([0, 0, 0]) do |total, child|
          specificity = selector_specificity(child)
          return nil if specificity.nil?
          total.zip(specificity).map { |left, right| left + right }
        end
      else
        nil
      end
    end
  end
end
