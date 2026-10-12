require "json"
require "logger"
require "uri"
require "nokogiri"
require "time"
require "peasant_path/patreon_rich_text"

module PeasantPath
  # Reads a Patreon collection or creator feed through Patreon's internal
  # JSON:API. Pure Ruby: every request goes through an injected transport, so
  # this class knows nothing about the browser that actually makes the call
  # (see PatreonSession) and can be tested against recorded JSON.
  #
  # The transport answers get_json(url) / get_text(url) / get_bytes(url) with
  # [status, body], and optionally landing_title for Cloudflare detection.
  class PatreonClient
    class ScrapeError < StandardError; end

    # Raised when the session is missing or Cloudflare interposed a challenge:
    # the operator has to run `patreon login`, nothing else will fix it.
    class AuthRequired < ScrapeError; end

    ROOT = "https://www.patreon.com".freeze
    API_VERSION = "json-api-version=1.0".freeze
    PAGE_FILTERS = "filter[contains_exclusive_posts]=true&filter[is_draft]=false".freeze
    # Patreon's creator pages are Next.js RSC streams where the bootstrap JSON
    # is embedded as a backslash-escaped string, so every quote may or may not
    # be preceded by a backslash.
    CAMPAIGN_ID_REGEX = /\\?"pageBootstrap\\?":\{\\?"campaign\\?":\{\\?"data\\?":\{\\?"id\\?":\\?"(\d+)\\?"/

    CURRENT_USER_URL = "#{ROOT}/api/current_user?#{API_VERSION}".freeze

    attr_writer :throttle

    def initialize(transport:, logger: Logger.new(File::NULL))
      @transport = transport
      @logger = logger
      @throttle = false
      @collections = {}
    end

    # Patreon answers a logged-out session with 200s and every post marked
    # unviewable, which a pull would misread as "nothing new". Library calls
    # this once per session so an expired login surfaces as AuthRequired.
    def verify_login!
      check_landing!
      status, _body = @transport.get_json(CURRENT_USER_URL)
      return true if status == 200

      raise AuthRequired, "Patreon session is not logged in (HTTP #{status}); run 'peasant_path patreon login'"
    end

    def fic_info(fic)
      ref = (fic.source_ref || {}).dup
      if ref["collection_id"]
        collection = collection_attributes(ref["collection_id"])
        ref["campaign_id"] ||= campaign_id_from_thumbnail(collection, ref["collection_id"])
        campaign = campaign_attributes(ref["campaign_id"])
        ref["vanity"] ||= campaign["vanity"]
        {
          description: plain_text(campaign["summary"]),
          title: collection["title"].to_s,
          author: campaign["name"].to_s,
          cover_image: fetch_bytes(collection.dig("thumbnail", "url"), "collection #{ref["collection_id"]} thumbnail"),
          volumes: [],
          volume_covers: {},
          source_ref: ref,
        }
      else
        ref["campaign_id"] ||= resolve_campaign_id(ref["vanity"])
        campaign = campaign_attributes(ref["campaign_id"])
        ref["vanity"] ||= campaign["vanity"]
        {
          description: plain_text(campaign["summary"]),
          title: campaign["name"].to_s,
          author: campaign["name"].to_s,
          cover_image: fetch_bytes(campaign["avatar_photo_url"], "campaign #{ref["campaign_id"]} avatar"),
          volumes: [],
          volume_covers: {},
          source_ref: ref,
        }
      end
    end

    # Returns only the chapters not yet in known_ids, ordered by order_number.
    # The list endpoint already carries the full body, so there is nothing
    # left for enrich_overview_chapter! to do.
    def chapter_overview(fic, known_ids: [])
      known = known_ids.map(&:to_s)
      ref = fic.source_ref || {}
      if ref["collection_id"]
        collection_overview(fic, ref, known)
      else
        creator_overview(fic, ref, known)
      end
    end

    def enrich_overview_chapter!(chapter)
      chapter
    end

    def resolve_campaign_id(vanity)
      raise ScrapeError, "cannot resolve a Patreon campaign without a vanity or campaign id" if vanity.to_s.empty?

      html = fetch_text("#{ROOT}/#{vanity}", "creator page #{vanity}")
      match = CAMPAIGN_ID_REGEX.match(html)
      if match.nil?
        raise ScrapeError, "creator page #{vanity}: could not find the campaign id in the page " \
                           "(Patreon markup may have changed, or an error page was served)"
      end
      match[1]
    end

    private

    def collection_overview(fic, ref, known)
      collection = collection_attributes(ref["collection_id"])
      campaign_id = ref["campaign_id"] || campaign_id_from_thumbnail(collection, ref["collection_id"])
      # post_ids is newest first and includes drafts; reversing it gives each
      # post a reading-order slot that does not move when a draft ahead of it
      # is published.
      order = Array(collection["post_ids"]).map(&:to_s).reverse.each_with_index.to_h
      url = posts_url(campaign_id, collection_id: ref["collection_id"], sort: "collection_order")

      new_chapters = walk_posts(fic, url, known, order, stop_when_known: true)
      # The early stop can miss posts that sit behind a page of known ones
      # (reordered, or an older draft just published). num_posts counts
      # published posts in the collection; when it says there are more than
      # we hold, walk every page once. Posts we hold that have since left the
      # collection do not trigger this: they can't be fetched anyway.
      expected = collection["num_posts"]
      held = known.count { |id| order.key?(id) } + new_chapters.size
      if expected && expected > held
        @logger.info("#{fic.fic_id}: collection reports #{expected} posts but we hold #{held}; re-walking every page")
        new_chapters = walk_posts(fic, url, known, order, stop_when_known: false)
      end
      new_chapters.sort_by(&:order_number)
    end

    def creator_overview(fic, ref, known)
      campaign_id = ref["campaign_id"] || resolve_campaign_id(ref["vanity"])
      url = posts_url(campaign_id, sort: "-published_at")
      # No post_ids to anchor on, so the whole feed is walked. Chapters are
      # write-once, so the order number must not depend on which other posts
      # are visible today: the publication timestamp itself is the order.
      walk_posts(fic, url, known, nil, stop_when_known: false).sort_by(&:order_number)
    end

    def posts_url(campaign_id, sort:, collection_id: nil)
      filters = "filter[campaign_id]=#{campaign_id}"
      filters += "&filter[collection_id]=#{collection_id}" if collection_id
      "#{ROOT}/api/posts?#{filters}&#{PAGE_FILTERS}&sort=#{sort}&#{API_VERSION}"
    end

    # Walks the paginated list. With stop_when_known, stops after the first
    # page on which every post is already on disk, which keeps incremental
    # pulls to one page. Returns Chapter objects for the posts collected.
    def walk_posts(fic, url, known, order, stop_when_known:)
      chapters = []
      next_url = url
      first = true
      while next_url
        sleep(rand(2..5)) if @throttle && !first
        first = false
        body = fetch_json(next_url, "posts page")
        posts = Array(body["data"])
        ids = posts.map { |p| p["id"].to_s }

        posts.each do |post|
          id = post["id"].to_s
          next if known.include?(id)
          chapter = build_chapter(fic, post, order)
          chapters << chapter if chapter
        end

        break if stop_when_known && !ids.empty? && ids.all? { |id| known.include?(id) }
        next_url = body.dig("links", "next")
      end
      chapters
    end

    def build_chapter(fic, post, order)
      attrs = post["attributes"] || {}
      id = post["id"].to_s
      label = "#{fic.fic_id} post #{id} (#{attrs["title"]})"

      unless attrs["current_user_can_view"]
        @logger.info("#{label}: not viewable with this account, skipped")
        return nil
      end
      raw = attrs["content_json_string"]
      if raw.to_s.empty?
        @logger.info("#{label}: empty body, skipped")
        return nil
      end

      doc = begin
          JSON.parse(raw)
        rescue JSON::ParserError => e
          raise ScrapeError, "#{label}: content_json_string is not valid JSON (#{e.message})"
        end
      warnings = []
      html = PatreonRichText.to_html(doc, warnings: warnings)
      warnings.uniq.each { |w| @logger.warn("#{label}: #{w}") }
      unless PatreonRichText.text?(html)
        @logger.info("#{label}: no readable text after conversion, skipped")
        return nil
      end

      chapter = Chapter.new(
        attrs["url"] || "#{ROOT}/posts/#{id}",
        fic_id: fic.fic_id,
        chapter_id: id,
        source: Sources::PATREON,
        repository: fic.repository,
      )
      chapter.chapter_title = attrs["title"].to_s.strip.empty? ? attrs["published_at"].to_s : attrs["title"].strip
      chapter.published_at = attrs["published_at"]
      chapter.chapter_text = html
      chapter.order_number = order ? order[id] : published_epoch(attrs["published_at"], label)
      if chapter.order_number.nil?
        # The list knows a post the collection's post_ids does not yet (added
        # while we walked). It would be persisted without a slot and never
        # revisited, so leave it for the next pull, which re-reads post_ids.
        @logger.info("#{label}: not in the collection's post order yet, deferred to the next pull")
        return nil
      end
      chapter
    end

    def published_epoch(value, label)
      Time.iso8601(value.to_s).to_i
    rescue ArgumentError
      raise ScrapeError, "#{label}: published_at #{value.inspect} is not a timestamp"
    end

    # fic_info and chapter_overview both need the collection, and a client
    # lives for exactly one pull, so one fetch per collection is enough.
    def collection_attributes(collection_id)
      @collections[collection_id] ||= begin
          body = fetch_json("#{ROOT}/api/collection/#{collection_id}?#{API_VERSION}", "collection #{collection_id}")
          attrs = body.dig("data", "attributes")
          raise ScrapeError, "collection #{collection_id}: response has no data.attributes" if attrs.nil?
          attrs
        end
    end

    def campaign_attributes(campaign_id)
      url = "#{ROOT}/api/campaigns/#{campaign_id}?fields[campaign]=name,vanity,url,avatar_photo_url,summary&#{API_VERSION}"
      body = fetch_json(url, "campaign #{campaign_id}")
      attrs = body.dig("data", "attributes")
      raise ScrapeError, "campaign #{campaign_id}: response has no data.attributes" if attrs.nil?
      attrs
    end

    # The collection payload has no campaign relationship, but its thumbnail
    # lives under /campaign/<id>/ on the CDN.
    def campaign_id_from_thumbnail(collection, collection_id)
      url = collection.dig("thumbnail", "url").to_s
      match = %r{/campaign/(\d+)/}.match(url)
      raise ScrapeError, "collection #{collection_id}: could not derive the campaign id from the thumbnail URL" if match.nil?
      match[1]
    end

    def fetch_json(url, context)
      check_landing!
      status, body = @transport.get_json(url)
      ensure_success!(status, context)
      raise ScrapeError, "#{context}: response was not JSON" unless body.is_a?(Hash)
      body
    end

    def fetch_text(url, context)
      check_landing!
      status, body = @transport.get_text(url)
      ensure_success!(status, context)
      body.to_s
    end

    def fetch_bytes(url, context)
      raise ScrapeError, "#{context}: no image URL in the response" if url.to_s.empty?
      status, body = @transport.get_bytes(url)
      ensure_success!(status, context)
      body
    end

    def check_landing!
      return unless @transport.respond_to?(:landing_title)
      title = @transport.landing_title.to_s
      raise AuthRequired, "Patreon served a Cloudflare challenge (#{title.strip}); run 'peasant_path patreon login'" if title =~ /just a moment/i
    end

    def ensure_success!(status, context)
      case status
      when 200 then nil
      when 401, 403
        raise AuthRequired, "#{context}: Patreon returned HTTP #{status}; run 'peasant_path patreon login'"
      when 429
        raise ScrapeError, "#{context}: Patreon returned 429 Too Many Requests"
      else
        raise ScrapeError, "#{context}: Patreon returned HTTP #{status}"
      end
    end

    def plain_text(html)
      fragment = Nokogiri::HTML.fragment(html.to_s)
      paragraphs = fragment.css("p").map { |p| p.text.strip }.reject(&:empty?)
      paragraphs.empty? ? fragment.text.strip : paragraphs.join("\n\n")
    end
  end
end
