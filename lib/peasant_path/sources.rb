require "uri"

module PeasantPath
  # Everything that is per-source but not per-client lives here: how a URL
  # maps to a fic, and the few display/format facts the rest of the app needs
  # (a human label, the EPUB anchor prefix). Adding a source means adding a
  # row to INFO and a resolver; nothing else in the app switches on the name.
  module Sources
    class InvalidURL < StandardError; end

    ROYALROAD = "royalroad".freeze
    PATREON = "patreon".freeze

    INFO = {
      # The RoyalRoad anchor prefix is part of the EPUB output readers link to;
      # it must not change.
      ROYALROAD => { label: "Royal Road", anchor_prefix: "rr-ch" }.freeze,
      PATREON => { label: "Patreon", anchor_prefix: "pt-ch" }.freeze,
    }.freeze

    ROYALROAD_FICTION = %r{\A/fiction/(\d+)(?:/|\z)}
    PATREON_COLLECTION = %r{\A/collection/(\d+)(?:/|\z)}
    # /<vanity>, /<vanity>/posts, /c/<vanity>, /cw/<vanity>
    PATREON_CREATOR = %r{\A/(?:c/|cw/)?([A-Za-z0-9_.-]+)(?:/posts)?/?\z}
    # Top-level Patreon paths that are pages, not creator vanities.
    PATREON_RESERVED = %w[posts login home collection api checkout join settings explore messages notifications search create signup user].freeze

    def self.label(source)
      INFO.fetch(source, INFO[ROYALROAD])[:label]
    end

    def self.anchor_prefix(source)
      INFO.fetch(source, INFO[ROYALROAD])[:anchor_prefix]
    end

    def self.resolve(url)
      begin
        uri = URI(url.to_s)
      rescue URI::InvalidURIError
        raise InvalidURL, "'#{url}' is not a valid URL"
      end

      unless %w[http https].include?(uri.scheme.to_s)
        raise InvalidURL, "'#{url}' is not a RoyalRoad or Patreon URL"
      end

      case uri.host
      when "www.royalroad.com", "royalroad.com"
        resolve_royalroad(url, uri)
      when "www.patreon.com", "patreon.com"
        resolve_patreon(url, uri)
      else
        raise InvalidURL, "'#{url}' is not a RoyalRoad or Patreon URL"
      end
    end

    def self.royalroad_uri(fic_id)
      "https://www.royalroad.com/fiction/#{fic_id}/"
    end

    def self.resolve_royalroad(url, uri)
      match = ROYALROAD_FICTION.match(uri.path.to_s)
      raise InvalidURL, "'#{url}' is not a RoyalRoad story URL" if match.nil?

      { source: ROYALROAD, fic_id: match[1], uri: royalroad_uri(match[1]), source_ref: {} }
    end

    def self.resolve_patreon(url, uri)
      path = uri.path.to_s
      if (match = PATREON_COLLECTION.match(path))
        return {
                 source: PATREON,
                 fic_id: "patreon-col-#{match[1]}",
                 uri: "https://www.patreon.com/collection/#{match[1]}",
                 source_ref: { "collection_id" => match[1] },
               }
      end

      # Old-style creator links look like /user?u=<id>; the numeric id works
      # as a vanity (Patreon serves /u<id>), so map it onto the same shape.
      if path == "/user" && (user_id = URI.decode_www_form(uri.query.to_s).to_h["u"]) && user_id =~ /\A\d+\z/
        return creator("u#{user_id}")
      end

      match = PATREON_CREATOR.match(path)
      if match.nil? || PATREON_RESERVED.include?(match[1].downcase)
        raise InvalidURL, "'#{url}' is not a Patreon collection or creator URL"
      end

      creator(match[1])
    end

    # The campaign id behind a vanity needs the network; the first pull fills
    # it into source_ref. The directory keeps the vanity-based id so following
    # stays offline, as it is for RoyalRoad. Vanities are case-insensitive on
    # Patreon, so they are downcased to keep one directory per creator.
    def self.creator(vanity)
      vanity = vanity.downcase
      {
        source: PATREON,
        fic_id: "patreon-v-#{vanity}",
        uri: "https://www.patreon.com/#{vanity}/posts",
        source_ref: { "vanity" => vanity },
      }
    end
  end
end
