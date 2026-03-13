require "json"
require "gepub"

class Epub
  attr_reader :fic, :book, :repo

  def initialize(fic)
    @fic = fic
    @book = GEPUB::Book.new
  end

  def build(target_path)
    @book = Epub.set_metadata(@fic, @book)
    @book = Epub.add_chapters(@fic, @book)
    @book.generate_epub(target_path)
  end

  def self.set_metadata(fic, book)
    book.primary_identifier('https://www.royalroad.com/fiction/#{fic.fic_id}/', "BookID", "URL")
    book.add_title(fic.title, title_type: GEPUB::TITLE_TYPE::MAIN, lang: "en", display_seq: 1)
    book.add_creator(fic.author, display_seq: 1)

    File.open(fic.repository.cover_image_path(fic.fic_id)) do |f|
      book.add_item("img/cover_image.jpg", content: f).cover_image
    end
    book.ordered do
      book.add_item("text/cover.xhtml", content: format_title_page(fic.title, "img/cover_image.jpg")).landmark(type: "cover", title: "cover page")
    end
    book
  end

  def self.add_chapters(fic, book)
    book.ordered do
      fic.chapters.each_with_index do |c, i|
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
    fragment.css("p").each { |el| el.remove if el.text.strip == " " }

    StringIO.new(<<~TEXT)
      <html xmlns="http://www.w3.org/1999/xhtml">
      <head><title>#{chapter.chapter_title}</title></head>
      <body>
      <h2>#{chapter.chapter_title}</h2>
      #{fragment.to_xhtml}</body></html>
    TEXT
  end
end
