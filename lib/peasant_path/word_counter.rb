require "nokogiri"

if RUBY_PLATFORM.include?("darwin") && ENV["FFI_ICU_LIB"].to_s.empty?
  ["/opt/homebrew/opt/icu4c@78/lib", "/usr/local/opt/icu4c@78/lib"].each do |path|
    if File.directory?(path)
      ENV["FFI_ICU_LIB"] = path
      break
    end
  end
end

require "ffi-icu"

module PeasantPath
  class WordCounter
    DEFAULT_LOCALE = "en_US".freeze

    def self.count_html(html, locale: DEFAULT_LOCALE)
      fragment = Nokogiri::HTML.fragment(html.to_s)
      fragment.css("script, style").remove
      count_text(fragment.text, locale: locale)
    end

    def self.count_text(text, locale: DEFAULT_LOCALE)
      text = text.to_s
      iterator = ICU::BreakIterator.new(:word, locale)
      iterator.text = text

      iterator.to_a.each_cons(2).count do |start_pos, end_pos|
        text[start_pos...end_pos].match?(/[[:alnum:]]/)
      end
    end
  end
end
