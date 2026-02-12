require 'json'
require 'gepub'

class Epub
  attr_reader :fic, :book

  def initialize(fic)
    @fic = fic
    @book = GEPUB::Book.new
  end

  def build(target_path)
    @book = Epub.set_metadata(@fic, @book)
    @book = Epub.add_chapters(@fic, @book)
    File.write(target_path, "An Epub goes here")
    @book.generate_epub(target_path)
  end

  def self.set_metadata(fic, book)
    book.primary_identifier('https://www.royalroad.com/ficion/#{fic.fic_id}/', 'BookID', 'URL')
    book.add_title(fic.title, title_type: GEPUB::TITLE_TYPE::MAIN, lang: 'en', display_seq: 1)
    book.add_creator(fic.author, display_seq: 1)

    book
  end

  def self.add_chapters(fic, book)
    book.ordered do
      fic.chapters.each do |c|
      book.add_item('text/chapter-1.xhtml')
        .add_content(format_chapter_in_xhtml(c))
        .toc_text('Chapter 1')
        .landmark(type: 'bodymatter', title: 'placeholder')
      end
    end
    book
  end

  def self.format_chapter_in_xhtml(chapter)
    StringIO.new(<<~TEXT)
    <html xmlns="http://www.w3.org/1999/xhtml">
    <head><title>#{chapter.chapter_title}</title></head>
    <body>#{chapter.chapter_text}</body></html>
    TEXT
  end
end
