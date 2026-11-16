require "json"
require "fileutils"
require "time"

module PeasantPath
  class Fic
    class MissingState < StandardError; end

    attr_accessor :title, :uri, :author, :description, :display_name, :volumes, :stats, :source, :source_ref
    attr_reader :fic_id, :repository

    # RoyalRoad is the default source: fic_info.json files without source
    # keys are RoyalRoad fics, and their numeric id is enough to rebuild the
    # URI.
    def initialize(fic_id:, repository:, source: Sources::ROYALROAD, uri: nil, source_ref: {})
      @repository = repository
      @fic_id = fic_id
      @source = source
      @uri = uri || Sources.royalroad_uri(fic_id)
      @source_ref = source_ref
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

    # Cheap count for display: the chapters in the EPUB, from the stats when
    # the chapters are not loaded, else by listing the chapter files.
    def chapter_count
      return book_chapters.size if @chapters

      @stats&.dig("chapter_count") || @repository.list_chapters(@fic_id).size
    end

    def word_count_estimate
      @stats&.dig("word_count_estimate")
    end

    # A story needs an identifier from when it is added, and it can't be empty
    # without breaking the web UI rendering.
    def display_title
      @display_name || @title || @fic_id
    end

    def patreon?
      @source == Sources::PATREON
    end

    def self.from_disk(fic_id, repository)
      content = repository.read_fic_info(fic_id)
      fic = new(
        fic_id: fic_id,
        repository: repository,
        source: content["source"] || Sources::ROYALROAD,
        uri: content["uri"],
        source_ref: content["source_ref"] || {},
      )
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
        .sort_by { |chapter| reading_order_key(chapter) }
    end

    # Royal Road's order number is a chapter's position in the chapter list
    # as it stood when the chapter was pulled. Authors stub a story ahead of a
    # book release by taking chapters off the front of that list, which
    # renumbers everything after them, so numbers saved before and after a
    # stub collide. Royal Road hands out chapter ids in the order chapters are
    # created, and authors very nearly always publish in that order, so the
    # id stands in for the reading order and stays put however much of the
    # story is stubbed. A chapter an author inserts or moves later lands where
    # its creation date puts it.
    # Patreon ids carry no order; its chapters keep the order number the
    # client derives.
    def reading_order_key(chapter)
      return [0, chapter.chapter_id.to_i] if @source == Sources::ROYALROAD

      [chapter.order_number.nil? ? 1 : 0, chapter.order_number || chapter.chapter_id.to_i]
    end

    def apply_fic_info(info)
      @author = info[:author]
      @title = info[:title]
      @cover_image = info[:cover_image]
      @description = info[:description]
      @volumes = info[:volumes]
      @volume_covers = info[:volume_covers]
      @source_ref = @source_ref.merge(info[:source_ref]) if info[:source_ref]

      self
    end

    # Library#rename writes the display name straight to disk, while a pull or
    # rebuild can hold this Fic for minutes. Taking the stored name before
    # persisting or building keeps them from writing back, or building under,
    # a name that has since changed.
    def reload_display_name!
      @display_name = @repository.read_fic_info(@fic_id)["display_name"] if @repository.fic_info_exists?(@fic_id)
      self
    end

    # The chapters that go into the EPUBs: everything pulled but stubbing
    # teasers.
    def book_chapters
      chapters.reject(&:teaser?)
    end

    def refresh_stats!
      loaded_chapters = book_chapters
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

    # The fic ID (RoyalRoad's numeric id, or the source-prefixed id Sources
    # derives for Patreon) is the canonical identifier of a fic; title, author
    # and description are all mutable.
    #
    # Cover bytes are only written when we actually have them (i.e. after a
    # fresh #fetch_fic_info). A fic loaded via #from_disk carries nil covers, so
    # persisting one must never overwrite the existing cover files with empty
    # data — only the metadata JSON is rewritten in that case.
    def persist_fic_info
      chapters = self.chapters.map(&:to_slug)
      info = {
        schema_version: Config::SCHEMA_VERSION,
        source: @source,
        uri: @uri,
        source_ref: @source_ref,
        author: @author,
        title: @title,
        display_name: @display_name,
        description: @description,
        volumes: @volumes,
        chapters: chapters,
      }
      info[:stats] = @stats if @stats
      @repository.write_fic_info_hash(@fic_id, info)

      @repository.write_cover_image(@fic_id, @cover_image) if @cover_image
      @volume_covers&.each do |volume_id, image_data|
        @repository.write_volume_cover_image(@fic_id, volume_id, image_data)
      end
    end
  end
end
