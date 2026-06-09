require "json"

module PeasantPath
  # Represents a singular chapter of a fic.
  class Chapter
    attr_reader :fic_id, :chapter_id, :uri, :repository
    attr_accessor :chapter_title, :chapter_text, :next_chapter, :previous_chapter, :volume_id, :order_number

    CHAPTER_REGEX = /https:\/\/www\.royalroad\.com\/fiction\/(\d+)\/[0-9a-z-]+\/chapter\/(\d+)/

    def ==(other)
      self.class == other.class &&
        @fic_id == other.fic_id &&
        @chapter_id == other.chapter_id
    end

    def initialize(uri, repository)
      @uri = uri
      match = CHAPTER_REGEX.match(uri)
      @fic_id = match[1]
      @chapter_id = match[2]
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

      c
    end

    def self.from_overview_hash(hash, repo)
      c = new("https://www.royalroad.com#{hash["url"]}", repo)
      c.chapter_title = hash["title"]
      c.order_number = hash["order"]
      c.volume_id = hash["volumeId"]

      c
    end

    def to_slug
      @chapter_id
    end

    # Chapters are write-once: once a chapter is on disk we never re-fetch it, so
    # an upstream edit to an already-pulled chapter is intentionally not picked
    # up. Persisting an existing chapter is therefore a no-op.
    def persist
      raise "Fetch the chapter before trying to save it to disk." if @chapter_title.nil? || @chapter_text.nil?
      return self if @repository.chapter_exists?(@fic_id, @chapter_id)

      body = JSON.pretty_generate({
        fic_id: @fic_id,
        chapter_uri: @uri,
        chapter_title: @chapter_title,
        chapter_text: @chapter_text,
        next_chapter: @next_chapter,
        previous_chapter: @previous_chapter,
        volume_id: @volume_id,
        order_number: @order_number,
      })
      @repository.write_chapter(@fic_id, @chapter_id, body)

      self
    end
  end
end
