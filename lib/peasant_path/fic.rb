require "json"
require "fileutils"
require "time"

module PeasantPath
  class Fic
    class MissingState < StandardError; end

    attr_accessor :title, :uri, :author, :description, :display_name, :volumes, :stats
    attr_reader :fic_id, :repository

    def initialize(fic_id:, repository:)
      @repository = repository
      @fic_id = fic_id
      @uri = Sources.uri_for(fic_id)
      @chapters = nil
      @title = nil
      @author = nil
      @display_name = nil
      @volumes = []
      @stats = nil
    end

    # Chapter contents are only read from disk on first access. Display-only
    # callers (the web index, download filenames) never need them, and reading
    # every chapter of every fic per request made the index slow.
    def chapters
      @chapters ||= discover_chapters_on_disk
    end

    # Cheap count for display: lists the chapter files without reading them.
    def chapter_count
      @chapters ? @chapters.size : @repository.list_chapters(@fic_id).size
    end

    def word_count_estimate
      @stats&.dig("word_count_estimate")
    end

    def display_title
      @display_name || @title
    end

    # The source this fic was pulled from, derived from fic_id (see Sources).
    def source
      Sources.key_for_fic_id(@fic_id)
    end

    def self.from_disk(fic_id, repository)
      content = repository.read_fic_info(fic_id)
      fic = new(fic_id: fic_id, repository: repository)
      fic.author = content["author"]
      fic.title = content["title"]
      fic.description = content["description"]
      fic.display_name = content["display_name"]
      fic.volumes = content["volumes"] || []
      fic.stats = content["stats"]

      fic
    rescue Errno::ENOENT
      raise MissingState, "Missing fic metadata for #{fic_id}"
    end

    def discover_chapters_on_disk
      @repository
        .list_chapters(@fic_id)
        .map { |chapter_file| Chapter.from_disk_content(@repository.read_chapter_from_path(chapter_file), @repository) }
        .sort_by { |chapter| [chapter.order_number.nil? ? 1 : 0, chapter.order_number || chapter.chapter_id.to_i] }
    end

    def apply_fic_info(info)
      @author = info[:author]
      @title = info[:title]
      @cover_image = info[:cover_image]
      @description = info[:description]
      @volumes = info[:volumes]
      @volume_covers = info[:volume_covers]

      self
    end

    def refresh_stats!
      loaded_chapters = chapters
      @stats = {
        "word_count_estimate" => loaded_chapters.sum(&:word_count_estimate),
        "chapter_count" => loaded_chapters.size,
        "updated_at" => Time.now.utc.iso8601,
      }

      @volumes = @volumes.map do |volume|
        volume_chapters = loaded_chapters.select { |chapter| chapter.volume_id.to_s == volume["id"].to_s }
        volume.merge(
          "word_count_estimate" => volume_chapters.sum(&:word_count_estimate),
          "chapter_count" => volume_chapters.size,
          "chapter_ids" => volume_chapters.map(&:chapter_id),
        )
      end

      persist_fic_info
      self
    end

    # Build from the chapters currently on disk. Does not pull; callers that
    # want fresh chapters should #pull first.
    def book
      Epub.new(self)
    end

    # The fic ID (source-scoped, see Sources) is considered the canon
    # identifier of a fic; after that, title and author and description are
    # all mutable.
    #
    # Cover bytes are only written when we actually have them (i.e. after a
    # fresh #fetch_fic_info). A fic loaded via #from_disk carries nil covers, so
    # persisting one must never overwrite the existing cover files with empty
    # data — only the metadata JSON is rewritten in that case.
    def persist_fic_info
      chapters = self.chapters.map(&:to_slug)
      info = { schema_version: Config::SCHEMA_VERSION, author: @author, title: @title, display_name: @display_name, description: @description, volumes: @volumes, chapters: chapters }
      info[:stats] = @stats if @stats
      @repository.write_fic_info_hash(@fic_id, info)

      @repository.write_cover_image(@fic_id, @cover_image) if @cover_image
      @volume_covers&.each do |volume_id, image_data|
        @repository.write_volume_cover_image(@fic_id, volume_id, image_data)
      end
    end
  end
end
