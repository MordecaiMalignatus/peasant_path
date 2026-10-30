require "peasant_path/browser"

module PeasantPath
  # RoyalRoad sits behind Anubis, a proof-of-work interstitial that only a
  # browser running its JavaScript gets past, and behind Cloudflare, which
  # challenges browsers that look automated (see Browser.launch_options). A
  # headless Chromium loads the site once to earn the pass cookie, then
  # fetches every page from inside that tab so each request carries it. No
  # login is involved, so the context is throwaway rather than a saved
  # profile.
  module RoyalRoadSession
    HOME_URL = "https://www.royalroad.com/".freeze
    # Anubis titles its interstitial "Making sure you're not a bot!"; the
    # Cloudflare one in front of it says "Just a moment...". Matched as the
    # whole title so a chapter that happens to share the words is not taken
    # for a challenge. Raw HTML spells the apostrophe as an entity.
    CHALLENGE_TITLE = /\A\s*(?:Making sure you(?:'|&#39;)re not a bot!|Just a moment\.\.\.)\s*\z/i
    CHALLENGE_TIMEOUT_SECONDS = 60

    # In-page HTTP: [status, body] for an absolute or site-relative URL.
    class Transport
      def initialize(page)
        @page = page
      end

      # A pass that expires mid-session gets the challenge page back instead
      # of the content; navigating to the URL solves it again, after which the
      # fetch is retried once.
      def get_text(url)
        status, body = fetch(url)
        return [status, body] unless RoyalRoadSession.challenge?(body)

        RoyalRoadSession.pass_challenge(@page, url)
        fetch(url)
      end

      private

      # The challenge's redirects can still be settling when the first fetch
      # runs, which destroys the page's JS context under it; wait for the new
      # document and try again.
      def fetch(url, attempts: 3)
        result = @page.evaluate(FETCH_TEXT_JS, arg: url)
        [result["status"], result["body"]]
      rescue Playwright::Error => e
        raise unless e.message.include?("Execution context was destroyed") && (attempts -= 1).positive?

        @page.wait_for_load_state(state: "domcontentloaded")
        retry
      end

      FETCH_TEXT_JS = <<~JS.freeze
        async (url) => {
          const r = await fetch(url, { credentials: "include" });
          return { status: r.status, body: await r.text() };
        }
      JS
    end

    module_function

    # Yield a Transport bound to a page on royalroad.com that has passed the
    # bot check.
    def open
      Browser.with_playwright do |playwright|
        browser = playwright.chromium.launch(**Browser.launch_options(headless: true))
        begin
          # baseURL lets a mid-session challenge navigate to a site-relative
          # URL the same way fetch resolves it.
          context = browser.new_context(baseURL: HOME_URL, userAgent: Browser.headed_user_agent(playwright))
          page = context.new_page
          pass_challenge(page, HOME_URL)
          yield Transport.new(page)
        ensure
          browser.close
        end
      end
    end

    def challenge?(body)
      title = body.to_s[%r{<title>([^<]*)</title>}i, 1]
      !title.nil? && title.match?(CHALLENGE_TITLE)
    end

    # Navigate to +url+ and wait for the challenge's script to solve and
    # redirect back. The title is polled rather than awaited in-page because
    # that redirect tears down the execution context mid-wait. A document
    # that has just committed has no title yet, so an empty one is not taken
    # as a pass.
    def pass_challenge(page, url, timeout: CHALLENGE_TIMEOUT_SECONDS)
      page.goto(url)
      deadline = Time.now + timeout
      loop do
        title = current_title(page)
        if title && !title.empty? && !title.match?(CHALLENGE_TITLE)
          page.wait_for_load_state(state: "domcontentloaded")
          return
        end

        if Time.now > deadline
          raise RoyalRoadClient::ScrapeError, "RoyalRoad's bot check did not let the headless browser through within #{timeout}s (page title: #{title.inspect})"
        end

        sleep 0.5
      end
    end

    def current_title(page)
      page.title
    rescue Playwright::Error
      nil
    end
  end
end
