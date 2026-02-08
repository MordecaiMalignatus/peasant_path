require_relative './chapter'
require_relative './royal_road_client'

# Represents a singular chapter of a fic.
class Chapter
  attr_reader :fic_id, :chapter_id, :uri
  attr_accessor :chapter_title, :chapter_text, :authors_opening_note, :authors_closing_note, :next_chapter, :previous_chapter

  CHAPTER_REGEX = /https:\/\/www\.royalroad\.com\/fiction\/(\d+)\/[a-z-]+\/chapter\/(\d+)/

  def initialize(uri, config)
    raise 'Nil config passed in.' if config.nil?

    @uri = uri
    match = CHAPTER_REGEX.match(uri)
    @fic_id = match[1]
    @chapter_id = match[2]
    @config = config
    @state_path = "#{Config::STATE_HOME}/#{fic_id}"
  end

  def self.read_from_disk(file_path, config)
    content = JSON.parse(File.read(file_path))
    c = new(content['chapter_uri'], config)
    c.chapter_title = content['chapter_title']
    c.chapter_text = content['chapter_text']
    c
  end

  def persist
    if @chapter_title.nil? || @chapter_text.nil?
      raise 'Fetch the chapter before trying to save it to disk.'
    end

    file_slug = @uri.dup.split('/')[-1]
    body = {fic_id: @fic_id, chapter_uri: @uri, chapter_title: @chapter_title, chapter_text: @chapter_text}.to_json
    begin
      existing_chapter = File.read("#{@state_path}/#{file_slug}")
      diff = Diffy::Diff.new(body, existing_chapter)
      unless diff == ''
        puts "Found change in #{fic_id}/#{file_slug}, displaying diff:"
        puts diff
        puts "\nIf you want to accept these changes, delete the file at #{@state_path}/#{file_slug}"
      end
    rescue Errno::ENOENT
      if @config.verbose
        puts "Chapter #{chapter_title} not found, saving..."
      end
      File.write("#{@state_path}/#{file_slug}", body)
    end
  end

end
