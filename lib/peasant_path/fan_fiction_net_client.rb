require "ferrum"
require "httparty"
require "nokogiri"

module PeasantPath
  # FanFiction.net sits behind Cloudflare bot detection that blocks plain HTTP
  # clients (curl, HTTParty) at the TLS-fingerprint level, regardless of
  # headers or cookies — a real browser engine is required to get through.
  # This client drives headless Chrome via Ferrum instead of issuing HTTP
  # requests directly, unlike RoyalRoadClient.
  #
  # Unlike RoyalRoad, a story has no separate overview/TOC page: chapter 1's
  # page carries both the story metadata (#profile_top) and the full chapter
  # list (the #chap_select dropdown), so #fic_info and #chapter_overview both
  # resolve to that same page.
  class FanFictionNetClient
    # Raised when a fetched page doesn't contain the markup we scrape — the
    # site's layout changed, an error page was served, or (despite using a
    # real browser) a Cloudflare challenge slipped through.
    class ScrapeError < StandardError; end

    HOST = "www.fanfiction.net"
    STORY_URL_REGEX = /https:\/\/www\.fanfiction\.net\/s\/(\d+)/
    CHAPTER_URL_REGEX = /https:\/\/www\.fanfiction\.net\/s\/(\d+)\/(\d+)/
    USER_AGENT = "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36"

    # Unlike RoyalRoadClient, throttling here isn't optional: firing chapter
    # fetches back-to-back (the default when the CLI's --throttle flag isn't
    # passed) reads as bot-speed traffic to Cloudflare and triggers a
    # challenge partway through a large fic, even though each fetch is
    # already sequential. #throttle= is still accepted, matching the shared
    # client interface Library calls it through, but its value is ignored —
    # every fetch always pauses first.
    attr_writer :throttle

    def initialize
      @throttle = false
      @mutex = Mutex.new
      @last_fetch = nil
    end

    # The canonical story URL for a FanFiction.net native fic ID: chapter 1,
    # since there is no separate overview page.
    def self.story_uri(native_id)
      "https://#{HOST}/s/#{native_id}/1/"
    end

    def self.native_fic_id_from_url(uri)
      STORY_URL_REGEX.match(uri.to_s)&.[](1)
    end

    def self.chapter_ids_from_url(uri)
      match = CHAPTER_URL_REGEX.match(uri.to_s)
      match ? [match[1], match[2]] : nil
    end

    def fic_info(uri)
      doc = fetch(uri)
      profile = require_element(doc, "#profile_top", context: uri)

      {
        description: profile.at_css("> div[style]")&.text&.strip,
        title: profile.at_css("> b")&.text&.strip,
        author: profile.at_css("a[href^='/u/']")&.text&.strip,
        cover_image: download_cover(profile),
        volumes: [],
        volume_covers: {},
      }
    end

    # Pick out the chapter titles and their URLs from the #chap_select
    # navigation dropdown (there's no separate TOC page or JS state to read,
    # unlike RoyalRoad). Returns the same hash shape RoyalRoadClient does:
    # absolute url, title, order — consumed by Chapter.from_overview_hash.
    #
    # A single-chapter story has no dropdown at all — there's nothing to
    # navigate to/from — so its absence isn't an error, just a one-chapter
    # story.
    def chapter_overview(fic_id)
      native_id = Sources.native_id_for_fic_id(fic_id)
      uri = self.class.story_uri(native_id)
      doc = fetch(uri)
      select = doc.at_css("#chap_select")

      return single_chapter_overview(native_id) if select.nil?

      select.css("option").map do |opt|
        chapter_num = opt["value"]
        {
          "title" => opt.text.strip.sub(/\A\d+\.\s*/, ""),
          "order" => chapter_num.to_i - 1,
          "url" => "https://#{HOST}/s/#{native_id}/#{chapter_num}/",
        }
      end
    end

    def enrich_overview_chapter!(overview_chapter)
      raise ArgumentError, "Chapter URI is required" if overview_chapter.uri.nil?

      doc = fetch(overview_chapter.uri)
      storytext = require_element(doc, "#storytext", context: overview_chapter.uri)

      overview_chapter.chapter_text = storytext.to_s
      overview_chapter
    end

    private

    # Loads +url+, or returns the previous fetch's result if it was for this
    # same url. #chapter_overview and #fic_info both resolve to the same
    # chapter-1 page for a given fic, and Library calls them back-to-back
    # while pulling that fic, so this turns what would otherwise be two full
    # throttled page loads into one. Only the single most recent fetch is
    # kept (not a full cache), so it can never go stale across separate
    # pulls — by the time a fic's chapter-1 page would come up again, many
    # other fics' and chapters' urls have already cycled through and evicted
    # it, which is exactly what should happen since a later pull needs a
    # fresh look for newly published chapters, not last time's answer.
    def fetch(url)
      @mutex.synchronize do
        cached_url, cached_doc = @last_fetch
        next cached_doc if cached_url == url

        doc = fetch_page(url)
        @last_fetch = [url, doc]
        doc
      end
    end

    # Loads +url+ in a fresh headless Chrome instance and returns the parsed
    # DOM. A browser is spun up per fetch rather than reused across calls, so
    # a crashed or hung Chrome process can never outlive a single scrape —
    # important for the unattended scheduled pulls this feeds into.
    #
    # The mutex around #fetch guarantees only one page is ever loading
    # through this client at a time — nothing in this codebase currently
    # fetches concurrently, but this makes it a hard invariant rather than
    # an incidental side effect of today's call sites staying sequential.
    def fetch_page(url)
      sleep(rand(5..15))
      browser = Ferrum::Browser.new(headless: true, browser_options: { "no-sandbox" => nil })
      browser.headers.set("User-Agent" => USER_AGENT)
      browser.goto(url)
      doc = Nokogiri::HTML(browser.body)

      if doc.at_css("title")&.text.to_s.include?("Just a moment")
        raise ScrapeError, "#{url}: hit a Cloudflare challenge page instead of real content"
      end

      doc
    ensure
      browser&.quit
    end

    def single_chapter_overview(native_id)
      [{
        "title" => "Chapter 1",
        "order" => 0,
        "url" => self.class.story_uri(native_id),
      }]
    end

    def require_element(doc, selector, context:)
      doc.at_css(selector) || raise(ScrapeError, "#{context}: could not find `#{selector}` in the page " \
      "(FanFiction.net markup may have changed, or an error/challenge page was served)")
    end

    def download_cover(profile)
      src = profile.at_css("img.cimage")&.[]("src")
      return nil if src.nil?

      url = src.start_with?("http") ? src : "https://#{HOST}#{src}"
      resp = HTTParty.get(url)
      raise ScrapeError, "cover_image: got unexpected response code #{resp.code} from #{url}" unless resp.code == 200

      resp.body
    end
  end
end
