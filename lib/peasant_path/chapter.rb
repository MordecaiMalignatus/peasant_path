require "json"

module PeasantPath
  # Represents a singular chapter of a fic.
  class Chapter
    class InvalidURL < ArgumentError; end

    attr_reader :fic_id, :chapter_id, :uri, :repository, :source
    attr_writer :word_count_estimate
    attr_accessor :chapter_title, :chapter_text, :next_chapter, :previous_chapter, :volume_id, :order_number, :published_at

    CHAPTER_REGEX = /https:\/\/www\.royalroad\.com\/fiction\/(\d+)\/[0-9a-z-]+\/chapter\/(\d+)/

    def ==(other)
      self.class == other.class &&
        @fic_id == other.fic_id &&
        @chapter_id == other.chapter_id
    end

    # Two construction styles:
    #   Chapter.new(rr_url, repo)                                    # ids parsed out of a RoyalRoad URL
    #   Chapter.new(url, fic_id:, chapter_id:, source:, repository:) # ids given explicitly (Patreon)
    # RoyalRoad chapter URLs encode both ids, so parsing them is the natural
    # constructor there; other sources carry ids out of band. Explicit ids
    # must come with a source: defaulting it would hand a Patreon chapter a
    # RoyalRoad anchor without anyone noticing.
    def initialize(uri, repo = nil, fic_id: nil, chapter_id: nil, source: nil, repository: nil)
      @uri = uri
      @repository = repository || repo

      if fic_id || chapter_id
        raise ArgumentError, "fic_id:, chapter_id: and source: must be given together" unless fic_id && chapter_id && source

        @fic_id = fic_id.to_s
        @chapter_id = chapter_id.to_s
        @source = source
      else
        match = CHAPTER_REGEX.match(uri.to_s)
        raise InvalidURL, "Invalid RoyalRoad chapter URL: #{uri}" unless match

        @fic_id = match[1]
        @chapter_id = match[2]
        @source = Sources::ROYALROAD
      end
    end

    # Older chapter files carry neither chapter_id nor source; they are all
    # RoyalRoad chapters, so the ids are parsed from the URL.
    def self.from_disk_content(content, repo)
      c = if content["chapter_id"]
          new(content["chapter_uri"], fic_id: content["fic_id"], chapter_id: content["chapter_id"], source: content["source"], repository: repo)
        else
          new(content["chapter_uri"], repo)
        end
      c.chapter_title = content["chapter_title"]
      c.chapter_text = content["chapter_text"]
      c.next_chapter = content["next_chapter"]
      c.previous_chapter = content["previous_chapter"]
      c.volume_id = content["volume_id"]
      c.order_number = content["order_number"]
      c.published_at = content["published_at"]
      c.word_count_estimate = content["word_count_estimate"]

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

    # Stable per-source anchor used as the chapter heading id in the EPUB.
    def anchor_id
      "#{Sources.anchor_prefix(@source)}-#{@chapter_id}"
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
        chapter_id: @chapter_id,
        source: @source,
        chapter_uri: @uri,
        chapter_title: @chapter_title,
        chapter_text: @chapter_text,
        next_chapter: @next_chapter,
        previous_chapter: @previous_chapter,
        volume_id: @volume_id,
        order_number: @order_number,
        published_at: @published_at,
        word_count_estimate: word_count_estimate,
      })

      self
    end
  end
end
