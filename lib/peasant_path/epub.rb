require "json"
require "fileutils"
require "cgi"
require "gepub"
require "nokogiri"

module PeasantPath
  class Epub
    STUB_VOLUME_THRESHOLD = 10

    attr_reader :fic

    def initialize(fic)
      @fic = fic
    end

    # Build the combined EPUB into +dir+ (defaults to the current working
    # directory, preserving the CLI's behaviour). Returns the written path.
    def build(dir = Dir.pwd)
      generate(dir, @fic.repository.epub_filename(@fic.display_title), Epub.compile(
        title: @fic.display_title,
        author: @fic.author,
        cover_path: @fic.repository.cover_image_path(@fic.fic_id),
        chapters: @fic.chapters,
        identifier: @fic.uri,
      ))
    end

    # Not transactional: if a volume build raises partway through, the combined
    # EPUB (and any volumes built before the failure) are left in place. Low
    # stakes — the next rebuild overwrites them — but worth knowing.
    def build_all(dir = Dir.pwd)
      build(dir)
      build_volumes(dir)
    end

    def build_volumes(dir = Dir.pwd)
      non_stub_volumes.each do |vol|
        vol_title = "#{@fic.display_title} - #{vol["title"]}"
        generate(dir, @fic.repository.epub_filename(vol_title), Epub.compile(
          title: vol_title,
          author: @fic.author,
          cover_path: volume_cover_path(vol["id"]),
          chapters: chapters_for_volume(vol),
          identifier: "#{@fic.uri}#volume-#{vol["id"]}",
        ))
      end
    end

    def self.compile(title:, author:, cover_path:, chapters:, identifier:)
      book = GEPUB::Book.new
      book.primary_identifier(identifier, "BookID", "URL")
      book.add_title(title, title_type: GEPUB::TITLE_TYPE::MAIN, lang: "en", display_seq: 1)
      book.add_creator(author, display_seq: 1)

      # Not every source provides a cover (FanFiction.net doesn't), so
      # cover_path may point at a file that was never written.
      has_cover = cover_path && File.exist?(cover_path)
      if has_cover
        File.open(cover_path) do |f|
          book.add_item("img/cover_image.jpg", content: f).cover_image
        end
      end
      book.ordered do
        book.add_item("text/cover.xhtml", content: format_title_page(title, has_cover ? "img/cover_image.jpg" : nil)).landmark(type: "cover", title: "cover page")
      end
      book.ordered do
        chapters.each_with_index do |c, i|
          book.add_item("text/chapter-#{i}.xhtml")
            .add_content(format_chapter_in_xhtml(c))
            .toc_text(c.chapter_title)
            .landmark(type: "bodymatter", title: "placeholder")
        end
      end

      book
    end

    def self.format_title_page(title, cover_image_path)
      escaped_title = h(title)
      img_tag = cover_image_path ? %(<img src="../#{cover_image_path}" />) : ""
      StringIO.new(<<~TEXT)
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <title>#{escaped_title}</title>
         </head>
         <body>
         <h1>#{escaped_title}</h1>
         #{img_tag}
         </body></html>
      TEXT
    end

    def self.format_chapter_in_xhtml(chapter)
      fragment = Nokogiri::HTML.fragment(chapter.chapter_text)
      fragment.css("p").each { |el| el.remove if el.text.strip == " " }
      escaped_title = h(chapter.chapter_title)

      StringIO.new(<<~TEXT)
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>#{escaped_title}</title></head>
        <body>
        <h2 id="rr-ch-#{h(chapter.chapter_id)}">#{escaped_title}</h2>
        #{fragment.to_xhtml}</body></html>
      TEXT
    end

    def self.h(text)
      CGI.escapeHTML(text.to_s)
    end

    private

    # Generate the EPUB to a temp file then atomically rename it into place, so
    # a concurrent download never observes a half-written file. Returns the path.
    def generate(dir, filename, book)
      FileUtils.mkdir_p(dir)
      final = File.join(dir, filename)
      tmp = "#{final}.tmp"
      book.generate_epub(tmp)
      File.rename(tmp, final)
      final
    end

    def non_stub_volumes
      @fic.volumes.select { |vol| chapters_for_volume(vol).size >= STUB_VOLUME_THRESHOLD }
    end

    def chapters_for_volume(vol)
      @fic.chapters.select { |c| c.volume_id == vol["id"] }
    end

    def volume_cover_path(volume_id)
      vol_path = @fic.repository.volume_cover_image_path(@fic.fic_id, volume_id)
      File.exist?(vol_path) ? vol_path : @fic.repository.cover_image_path(@fic.fic_id)
    end
  end
end
