require "json"
require "fileutils"
require "diffy"

module PeasantRoad
  class Fic
    FIC_ID_REGEX = /https:\/\/www\.royalroad\.com\/fiction\/(\d+)\//

    attr_accessor :title, :uri, :author, :chapters, :description, :display_name
    attr_reader :rr, :fic_id, :repository

    def initialize(fic_id:, repository:)
      @repository = repository
      @fic_id = fic_id
      @uri = "https://www.royalroad.com/fiction/#{fic_id}/"
      @chapters = discover_chapters_on_disk
      @title = nil
      @author = nil
      @display_name = nil
      @rr = RoyalRoadClient.new
    end

    def display_title
      @display_name || @title
    end

    def self.from_disk(fic_id, repository)
      begin
        content = repository.read_fic_info(fic_id)
        fic = new(fic_id: fic_id, repository: repository)
        fic.author = content["author"]
        fic.title = content["title"]
        fic.description = content["description"]
        fic.display_name = content["display_name"]
      rescue Errno::ENOENT
        # Directory was deleted from disk, but entry not removed from config (usually the case in testing)
        puts "Fic metadata not found, retrieving..."
        fic = new(fic_id: fic_id, repository: repository)
        fic.fetch_fic_info
        fic.persist_fic_info
      end

      fic
    end

    def discover_chapters_on_disk
      @repository
        .list_chapters(@fic_id)
        .map { |chapter_file| Chapter.from_disk_content(@repository.read_chapter_from_path(chapter_file), @repository) }
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
      @chapters = discover_chapters_on_disk
      chapter_toc = @rr.chapter_overview(@fic_id).map { |title, uri| "https://www.royalroad.com#{uri}" }
      existing_chapters = @chapters.map { |c| c.uri }
      chapters_to_pull = chapter_toc.filter { |rr_chapter| !existing_chapters.include?(rr_chapter) }
      fetch_fic_info
      persist_fic_info
      puts "#{chapters_to_pull.size} new chapters, scraping..."

      chapters_to_pull.each do |link|
        @chapters << @rr.fetch_chapter(link, @repository).persist
      end
    end

    def to_book
      self.pull
      Epub.new(self)
    end

    # The RR fic ID found in the URL is considered the canon identifier of a fic,
    # after that, title and author and description are all mutable. Returns a
    # string-diff of what's changed.
    def persist_fic_info
      existing_state = { author: "", title: "", description: "", chapters: [] }
      begin
        existing_state = @repository.read_fic_info(@fic_id)
      rescue Errno::ENOENT
        puts "Fic information not found, starting from scratch"
      end

      chapters = @chapters.map(&:to_slug)
      new_state = JSON.pretty_generate({ author: @author, title: @title, display_name: @display_name, description: @description, chapters: chapters })

      puts Diffy::Diff.new(JSON.pretty_generate(existing_state), new_state)

      puts "Saving cover image..."
      @repository.write_cover_image(@fic_id, @cover_image)
      @repository.write_fic_info(@fic_id, new_state)
    end

    def self.uri_to_fic_id(uri)
      FIC_ID_REGEX.match(uri)[1]
    end

    def self.fic_id_to_uri(fic_id)
      "https://www.royalroad.com/fiction/#{fic_id}/"
    end
  end
end
