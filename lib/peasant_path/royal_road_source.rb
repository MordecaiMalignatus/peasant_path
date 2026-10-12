module PeasantPath
  # Adapts RoyalRoadClient to the per-source client interface Library drives:
  #   throttle=, fic_info(fic), chapter_overview(fic, known_ids:), enrich_overview_chapter!(chapter)
  # The client itself works in URLs and ids; this adapter is the only place
  # on the RoyalRoad side that knows what a Fic is.
  class RoyalRoadSource
    attr_reader :client

    def initialize(client = RoyalRoadClient.new)
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
    def chapter_overview(fic, known_ids: [])
      @client.chapter_overview(fic.fic_id).map { |hash| Chapter.from_overview_hash(hash, fic.repository) }
    end

    def enrich_overview_chapter!(chapter)
      @client.enrich_overview_chapter!(chapter)
    end
  end
end
