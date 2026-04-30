require "json"
require "fileutils"

module PeasantRoad
  class Fic
    FIC_ID_REGEX = /https:\/\/www\.royalroad\.com\/fiction\/(\d+)\//

    attr_accessor :title, :uri, :author, :chapters, :description, :display_name, :volumes
    attr_reader :rr, :fic_id, :repository

    def initialize(fic_id:, repository:)
      @repository = repository
      @fic_id = fic_id
      @uri = "https://www.royalroad.com/fiction/#{fic_id}/"
      @chapters = discover_chapters_on_disk
      @title = nil
      @author = nil
      @display_name = nil
      @volumes = []
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
        fic.volumes = content["volumes"] || []
      rescue Errno::ENOENT
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
      @volumes = info[:volumes]
      @volume_covers = info[:volume_covers]

      self
    end

    def pull
      @chapters = discover_chapters_on_disk
      chapter_toc = @rr.chapter_overview(@fic_id).map { |chapter_hash| Chapter.from_overview_hash(chapter_hash, @repository) }
      chapters_to_pull = chapter_toc.filter { |rr_chapter| !@chapters.include?(rr_chapter) }
      fetch_fic_info
      persist_fic_info

      new_chapters = chapters_to_pull.map { |c| @rr.enrich_overview_chapter!(c).persist }
      @chapters.concat(new_chapters)
      new_chapters
    end

    def to_book
      pull
      Epub.new(self)
    end

    # The RR fic ID found in the URL is considered the canon identifier of a fic,
    # after that, title and author and description are all mutable.
    def persist_fic_info
      chapters = @chapters.map(&:to_slug)
      new_state = JSON.pretty_generate({ author: @author, title: @title, display_name: @display_name, description: @description, volumes: @volumes, chapters: chapters })

      @repository.write_cover_image(@fic_id, @cover_image)
      @volume_covers&.each do |volume_id, image_data|
        @repository.write_volume_cover_image(@fic_id, volume_id, image_data)
      end
      @repository.write_fic_info(@fic_id, new_state)
    end

    def self.uri_to_fic_id(uri)
      FIC_ID_REGEX.match(uri)[1]
    end
  end
end
