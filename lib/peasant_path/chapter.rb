require "json"

module PeasantPath
  # Represents a singular chapter of a fic.
  class Chapter
    class InvalidURL < ArgumentError; end

    attr_reader :fic_id, :chapter_id, :uri, :repository
    attr_writer :word_count_estimate
    attr_accessor :chapter_title, :chapter_text, :next_chapter, :previous_chapter, :volume_id, :order_number

    def ==(other)
      self.class == other.class &&
        @fic_id == other.fic_id &&
        @chapter_id == other.chapter_id
    end

    def initialize(uri, repository)
      @uri = uri
      source_key, native_fic_id, native_chapter_id = Sources.chapter_ids_from_url(uri)
      raise InvalidURL, "Unrecognized chapter URL: #{uri}" unless source_key

      @fic_id = Sources.scoped_fic_id(source_key, native_fic_id)
      @chapter_id = native_chapter_id
      @repository = repository
    end

    def self.from_disk_content(content, repo)
      c = new(content["chapter_uri"], repo)
      c.chapter_title = content["chapter_title"]
      c.chapter_text = content["chapter_text"]
      c.next_chapter = content["next_chapter"]
      c.previous_chapter = content["previous_chapter"]
      c.volume_id = content["volume_id"]
      c.order_number = content["order_number"]
      c.word_count_estimate = content["word_count_estimate"]

      c
    end

    # hash["url"] is expected to already be an absolute URL — each client's
    # #chapter_overview is responsible for resolving its own relative paths.
    def self.from_overview_hash(hash, repo)
      c = new(hash["url"], repo)
      c.chapter_title = hash["title"]
      c.order_number = hash["order"]
      c.volume_id = hash["volumeId"]

      c
    end

    def to_slug
      @chapter_id
    end

    def word_count_estimate
      return @word_count_estimate unless @word_count_estimate.nil?

      @word_count_estimate = WordCounter.count_html(@chapter_text)
    end

    # Chapters are write-once: once a chapter is on disk we never re-fetch it, so
    # an upstream edit to an already-pulled chapter is intentionally not picked
    # up. Persisting an existing chapter is therefore a no-op.
    def persist
      raise ArgumentError, "Fetch the chapter before trying to save it to disk." if @chapter_title.nil? || @chapter_text.nil?
      return self if @repository.chapter_exists?(@fic_id, @chapter_id)

      @repository.write_chapter_hash(@fic_id, @chapter_id, {
        fic_id: @fic_id,
        chapter_uri: @uri,
        chapter_title: @chapter_title,
        chapter_text: @chapter_text,
        next_chapter: @next_chapter,
        previous_chapter: @previous_chapter,
        volume_id: @volume_id,
        order_number: @order_number,
        word_count_estimate: word_count_estimate,
      })

      self
    end
  end
end
