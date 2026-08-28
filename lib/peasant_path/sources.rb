module PeasantPath
  # Registry of known fic sources (RoyalRoad, and whatever follows it), so Fic,
  # Library, and Epub don't have to special-case RoyalRoad's URLs directly.
  #
  # A fic_id is either bare (a RoyalRoad native ID, kept unprefixed for
  # backward compatibility with fics already on disk) or "<source_key>:<native
  # id>" for every other source. There is no migration path for existing data
  # because of this: an unprefixed fic_id always means RoyalRoad.
  module Sources
    DEFAULT = "royalroad"

    REGISTRY = {
      DEFAULT => { client_class: RoyalRoadClient, hosts: [RoyalRoadClient::HOST] },
      "fanfictionnet" => { client_class: FanFictionNetClient, hosts: [FanFictionNetClient::HOST] },
    }.freeze

    def self.key_for_fic_id(fic_id)
      fic_id.to_s.include?(":") ? fic_id.to_s.split(":", 2).first : DEFAULT
    end

    def self.native_id_for_fic_id(fic_id)
      fic_id.to_s.include?(":") ? fic_id.to_s.split(":", 2).last : fic_id.to_s
    end

    def self.client_class_for(source_key)
      REGISTRY.fetch(source_key) { raise ArgumentError, "Unknown source: #{source_key}" }[:client_class]
    end

    def self.source_key_for_host(host)
      REGISTRY.find { |_, entry| entry[:hosts].include?(host) }&.first
    end

    # Returns [source_key, native_fic_id, native_chapter_id] for the first
    # registered client that recognizes +uri+ as one of its chapter URLs, or
    # nil if none do.
    def self.chapter_ids_from_url(uri)
      REGISTRY.each do |source_key, entry|
        native_ids = entry[:client_class].chapter_ids_from_url(uri)
        return [source_key, *native_ids] if native_ids
      end
      nil
    end

    def self.scoped_fic_id(source_key, native_id)
      source_key == DEFAULT ? native_id : "#{source_key}:#{native_id}"
    end

    def self.uri_for(fic_id)
      client_class_for(key_for_fic_id(fic_id)).story_uri(native_id_for_fic_id(fic_id))
    end
  end
end
