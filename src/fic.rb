require_relative './royal_road_client'
require_relative './config'
require_relative './epub'

require 'json'
require 'fileutils'

class Fic
  FIC_ID_REGEX = /https:\/\/www\.royalroad\.com\/fiction\/(\d+)\//

  attr_accessor :title, :uri, :author, :chapters, :description
  attr_reader :rr, :fic_id, :repository

  def initialize(fic_id:, chapters:, repository:)
    raise 'wtf' if fic_id.nil?
    raise 'missing required disk repository' if repository.nil?

    @repository = repository
    @fic_id = fic_id
    @uri = "https://www.royalroad.com/fiction/#{fic_id}/"
    if chapters.nil? || chapters.empty?
      @chapters = discover_chapters_on_disk
    end

    @title = nil
    @author = nil
    @rr = RoyalRoadClient.new(config)
  end

  def self.from_disk(fic_id, repository)
    begin
      content = repository.read_fic_info(fic_id)
      chapters = content['chapters'].map{ |slug| Chapter.read_from_disk("#{@state_path}/#{slug}.json", config) }

      fic = new(fic_id: fic_id, config: config, chapters: chapters)
      fic.author = content['author']
      fic.title = content['title']
      fic.description = content['description']
    rescue Errno::ENOENT
      # Directory was deleted from disk, but entry not removed from config (usually the case in testing)
      puts "Fic metadata not found, retrieving..."
      fic = new(fic_id: fic_id, chapters: nil)
      fic.fetch_fic_info
      fic.persist_fic_info
    end

    fic
  end

  def discover_chapters_on_disk()
    @repository
      .list_chapters(@fic_id)
      .map {|chapter_file| Chapter.read_from_disk(chapter_file, @config) }
  end

  def fetch_fic_info
    info = @rr.fic_info(@uri.to_s)
    @author = info[:author]
    @title = info[:title]
    @cover_image = info[:cover_image]
    @description = info[:description]
    self
  end

  def pull
    persist_fic_info
    chapter_toc = @rr.chapter_overview(@fic_id).map { |title, uri| "https://www.royalroad.com#{uri}" }
    existing_chapters = @chapters.map {|c| c.uri }
    chapters_to_pull = chapter_toc.filter { |rr_chapter| !existing_chapters.include?(rr_chapter) }

    if @config.verbose
      puts "#{chapters_to_pull.size} new chapters, scraping..."
    end

    chapters_to_pull.each do |link|
      @chapters << @rr.fetch_chapter(link).persist
    end
  end

  def to_book
    self.pull
    Epub.new(self)
  end

  def persist_fic_info()
    Fic.persist_fic_info(@fic_id, @author, @title, @description, @chapters, @cover_image, @config)
  end

  # The RR fic ID found in the URL is considered the canon identifier of a fic,
  # after that, title and author and description are all mutable. Returns a
  # string-diff of what's changed.
  def self.persist_fic_info(fic_id, author, title, description, chapters, cover_image, config)
    existing_state = {author: "", title: "", description: "", chapters: []}
    begin
      existing_state = @repository.read_fic_info(@fic_id)
    rescue Errno::ENOENT
      if config.verbose
        puts "Fic information not found, starting from blank"
      end
    end

    chapters = chapters.map(&:to_slug)
    new_state = JSON.pretty_generate({author: author, title: title, description: description, chapters: chapters})
    # TODO(sar): This is fine for now, but this diffs unprettied json and is not
    # fantastic. Also should be verbosity-gated.
    puts Diffy::Diff.new(existing_state, new_state)

    unless File.exist?("#{state_path}/cover_image.jpg")
      puts "Saving cover image..."
      @repository.write_cover_image(@fic_id, cover_image)
    end

    @repository.write_fic_infop(@fic_id, new_state)
  end

  def self.uri_to_fic_id(uri)
    FIC_ID_REGEX.match(uri)[1]
  end

  def self.fic_id_to_uri(fic_id)
    "https://www.royalroad.com/fiction/#{fic_id}/"
  end
end
