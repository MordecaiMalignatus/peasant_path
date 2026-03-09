require_relative './chapter'
require_relative './royal_road_client'
require_relative './config'

# Represents a singular chapter of a fic.
class Chapter
  attr_reader :fic_id, :chapter_id, :uri
  attr_accessor :chapter_title, :chapter_text, :next_chapter, :previous_chapter

  CHAPTER_REGEX = /https:\/\/www\.royalroad\.com\/fiction\/(\d+)\/[a-z-]+\/chapter\/(\d+)/

  def initialize(uri, config)
    raise 'Nil config passed in.' if config.nil?

    @uri = uri
    match = CHAPTER_REGEX.match(uri)
    @fic_id = match[1]
    @chapter_id = match[2]
    @config = config
  end

  def self.read_from_disk(content, config)
    c = new(content['chapter_uri'], config)
    c.chapter_title = content['chapter_title']
    c.chapter_text = content['chapter_text']
    c.next_chapter = content['next_chapter']
    c.previous_chapter = content['previous_chapter']
    c
  end

  def to_slug
    @chapter_id
  end

  def persist
    if @chapter_title.nil? || @chapter_text.nil?
      raise 'Fetch the chapter before trying to save it to disk.'
    end

    body = JSON.pretty_generate({
      fic_id: @fic_id,
      chapter_uri: @uri,
      chapter_title: @chapter_title,
      chapter_text: @chapter_text,
      next_chapter: @next_chapter,
      previous_chapter: @previous_chapter,
    })
    begin
      @repository.read_chapter(@fic_id, @chapter_id)
    rescue Errno::ENOENT
      if @config.verbose
        puts "Chapter #{chapter_title} not found, saving..."
      end
      @repository.write_chapter(@fic_id, @chapter_id, body)
    end

    self
  end
end
