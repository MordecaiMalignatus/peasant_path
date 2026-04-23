require "json"
require "gepub"
require "nokogiri"

module PeasantRoad
  class Epub
    STUB_VOLUME_THRESHOLD = 10

    attr_reader :fic

    def initialize(fic)
      @fic = fic
    end

    def build(target_path)
      Epub.compile(
        title: @fic.display_title,
        author: @fic.author,
        cover_path: @fic.repository.cover_image_path(@fic.fic_id),
        chapters: @fic.chapters,
        identifier: "https://www.royalroad.com/fiction/#{@fic.fic_id}/"
      ).generate_epub(target_path)
    end

    def build_all(combined_path)
      build(combined_path)
      build_volumes
    end

    def build_volumes
      non_stub_volumes.each do |vol|
        vol_title = "#{@fic.display_title} - #{vol['title']}"
        Epub.compile(
          title: vol_title,
          author: @fic.author,
          cover_path: volume_cover_path(vol["id"]),
          chapters: chapters_for_volume(vol),
          identifier: "https://www.royalroad.com/fiction/#{@fic.fic_id}/#volume-#{vol['id']}"
        ).generate_epub("#{vol_title}.epub")
      end
    end

    def self.compile(title:, author:, cover_path:, chapters:, identifier:)
      book = GEPUB::Book.new
      book.primary_identifier(identifier, "BookID", "URL")
      book.add_title(title, title_type: GEPUB::TITLE_TYPE::MAIN, lang: "en", display_seq: 1)
      book.add_creator(author, display_seq: 1)

      File.open(cover_path) do |f|
        book.add_item("img/cover_image.jpg", content: f).cover_image
      end
      book.ordered do
        book.add_item("text/cover.xhtml", content: format_title_page(title, "img/cover_image.jpg")).landmark(type: "cover", title: "cover page")
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
      StringIO.new(<<~TEXT)
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head>
          <title>#{title}</title>
         </head>
         <body>
         <h1>#{title}</h1>
         <img src="../#{cover_image_path}" />
         </body></html>
      TEXT
    end

    def self.format_chapter_in_xhtml(chapter)
      fragment = Nokogiri::HTML.fragment(chapter.chapter_text)
      fragment.css("p").each { |el| el.remove if el.text.strip == " " }

      StringIO.new(<<~TEXT)
        <html xmlns="http://www.w3.org/1999/xhtml">
        <head><title>#{chapter.chapter_title}</title></head>
        <body>
        <h2>#{chapter.chapter_title}</h2>
        #{fragment.to_xhtml}</body></html>
      TEXT
    end

    private

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
