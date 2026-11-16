module PeasantPath
  # Adapts RoyalRoadClient to the per-source client interface Library drives:
  #   throttle=, fic_info(fic), chapter_overview(fic, known_ids:), enrich_overview_chapter!(chapter)
  # The client itself works in URLs and ids; this adapter is the only place
  # on the RoyalRoad side that knows what a Fic is.
  class RoyalRoadSource
    attr_reader :client

    def initialize(client)
      @client = client
    end

    def throttle=(value)
      @client.throttle = value
    end

    def fic_info(fic)
      @client.fic_info(fic.uri.to_s)
    end

    # RoyalRoad's table of contents is one page, so known_ids is not needed to
    # bound the work; Library filters already-known chapters itself.
    #
    # known_ids does pick out stubbing teasers. Ahead of a book release
    # authors take a story's first chapters off Royal Road, often putting a
    # chapter that advertises the book in their place. A new chapter is taken
    # for such a teaser when Royal Road lists it ahead of chapters already
    # pulled and it is newer than all of them: written at stub time, but
    # filed where the stubbed chapters were. A chapter that comes back after
    # being hidden is older than the ones pulled meanwhile, so it is not
    # caught. A teaser is still saved, but left out of the EPUBs.
    def chapter_overview(fic, known_ids: [])
      known = known_ids.map(&:to_s)
      chapters = @client.chapter_overview(fic.fic_id).map { |hash| Chapter.from_overview_hash(hash, fic.repository) }
      last_known = chapters.rindex { |chapter| known.include?(chapter.chapter_id) }
      return chapters if last_known.nil?

      newest_known = known.map(&:to_i).max
      chapters.each_with_index do |chapter, i|
        next if known.include?(chapter.chapter_id)

        chapter.teaser = true if i < last_known && chapter.chapter_id.to_i > newest_known
      end
    end

    def enrich_overview_chapter!(chapter)
      @client.enrich_overview_chapter!(chapter)
    end
  end
end
