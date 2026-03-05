require_relative './royal_road_client'
require_relative './config'
require_relative './epub'

require 'json'
require 'fileutils'

class Fic
  FIC_ID_REGEX = /https:\/\/www\.royalroad\.com\/fiction\/(\d+)\//

  attr_accessor :title, :uri, :author, :chapters, :description
  attr_reader :rr, :fic_id, :state_path, :config

  def initialize(fic_id:, config:, chapters:)
    raise 'wtf' if fic_id.nil?

    @config = config
    @fic_id = fic_id
    @uri = "https://www.royalroad.com/fiction/#{fic_id}/"
    @state_path = "#{Config::STATE_HOME}/#{fic_id}"
    if chapters.nil? || chapters.empty?
      @chapters = discover_chapters_on_disk
    end

    @title = nil
    @author = nil
    @rr = RoyalRoadClient.new(config)
  end

  def self.from_disk(fic_id, config)
    state_path = "#{Config::STATE_HOME}/#{fic_id}"
    begin
      content = JSON.parse(File.read("#{state_path}/fic_info.json"))
      chapters = content['chapters'].map{ |slug| Chapter.read_from_disk("#{@state_path}/#{slug}.json", config) }

      fic = new(fic_id: fic_id, config: config, chapters: chapters)
      fic.author = content['author']
      fic.title = content['title']
      fic.description = content['description']
    rescue Errno::ENOENT
      # Directory was deleted from disk, but entry not removed from config (usually the case in testing)
      puts "Fic metadata not found, retrieving..."
      FileUtils.mkdir_p(state_path)
      fic = new(fic_id: fic_id, config: config, chapters: nil)
      fic.fetch_fic_info
      fic.persist_fic_info
    end

    fic
  end

  def discover_chapters_on_disk()
    items = Dir.glob("#{@state_path}/*")
    if items.empty?
      puts "No existing fic_info.json file found when discovering, starting from scratch..."
      []
    else
      chapters = items - ["#{@state_path}/fic_info.json", "#{@state_path}/cover_image.jpg"]
      chapters.map {|chapter_file| Chapter.read_from_disk(chapter_file, @config) }
    end
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

  # Well, by default, the chapters are in the order that Glob finds them in,
  # usually lexicographical. This is not the same as you know, reading order.
  # Luckily we capture that information in the chapter files.
  def order_chapters
    raise 'TODO'
  end

  def to_book
    self.pull
    Epub.new(self)
  end

  def cover_image_path
    "#{state_path}/cover_image.jpg"
  end

  def persist_fic_info()
    Fic.persist_fic_info(@fic_id, @author, @title, @description, @chapters, @cover_image, @config)
  end

  # The RR fic ID found in the URL is considered the canon identifier of a fic,
  # after that, title and author and description are all mutable. Returns a
  # string-diff of what's changed.
  def self.persist_fic_info(fic_id, author, title, description, chapters, cover_image, config)
    existing_state = {author: "", title: "", description: "", chapters: []}
    state_path = "#{Config::STATE_HOME}/#{fic_id}"
    begin
      existing_state = File.read("#{state_path}/fic_info.json")
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

    FileUtils.mkdir_p(state_path)

    unless File.exist?("#{state_path}/cover_image.jpg")
      puts "Saving cover image..."
      File.write("#{state_path}/cover_image.jpg", cover_image)
    end

    File.write("#{state_path}/fic_info.json", new_state)
  end

  def self.uri_to_fic_id(uri)
    FIC_ID_REGEX.match(uri)[1]
  end

  def self.fic_id_to_uri(fic_id)
    "https://www.royalroad.com/fiction/#{fic_id}/"
  end
end
