require "fileutils"
require "json"
require "peasant_path/browser"

module PeasantPath
  # Patreon sits behind Cloudflare's TLS fingerprinting, so a plain HTTP
  # client with exported cookies gets 403s; every Patreon request is therefore
  # made from inside a Playwright page (same-origin `fetch`), reusing a
  # persistent browser profile that a human logged into once via #login.
  module PatreonSession
    NotInstalled = Browser::NotInstalled
    class LoginAborted < StandardError; end

    # Another process (the web daemon's pull, a systemd refresh, a second CLI)
    # has the profile open. Two browsers on one profile corrupt it.
    class Busy < StandardError; end

    HOME_URL = "https://www.patreon.com/".freeze
    LOGIN_URL = "https://www.patreon.com/login".freeze
    CURRENT_USER_URL = "https://www.patreon.com/api/current_user?json-api-version=1.0".freeze
    # Chromium's profile lock: SingletonLock is a symlink to "<host>-<pid>".
    # Left behind by a crash it blocks the next launch; held by a live process
    # it is the only thing stopping a second browser from corrupting the
    # profile, so it is cleared only when that pid is gone.
    LOCK_FILES = %w[SingletonLock SingletonSocket SingletonCookie].freeze

    # In-page HTTP. Each call runs `fetch` inside the logged-in page so the
    # request carries the browser's cookies and TLS fingerprint.
    class Transport
      attr_reader :landing_title

      def initialize(page, landing_title)
        @page = page
        @context = page.context
        @landing_title = landing_title
      end

      def get_json(url)
        status, text = get_text(url)
        parsed = begin
            JSON.parse(text)
          rescue JSON::ParserError
            nil
          end
        [status, parsed]
      end

      def get_text(url)
        result = @page.evaluate(FETCH_TEXT_JS, arg: url)
        [result["status"], result["body"]]
      end

      # The cookies that make up the login, in the shape add_cookies accepts.
      def patreon_cookies
        @context.cookies.select { |c| c["domain"].to_s.end_with?("patreon.com") }
      end

      # Covers and images live on patreonusercontent.com, a different origin
      # without CORS headers, so an in-page `fetch` cannot read their bodies.
      # Navigate a throwaway tab there instead: still the browser's cookies
      # and TLS fingerprint, and Playwright hands us the raw response body.
      def get_bytes(url)
        tab = @context.new_page
        begin
          # The CDN content-negotiates: a browser's default Accept (which
          # lists image/webp) can get WebP back even for a .png URL, and WebP
          # is not safe in EPUB covers. Rewrite the Accept header on the wire
          # (set_extra_http_headers does not reach navigations) so the classic
          # formats are the only ones on offer.
          tab.route("**/*", ->(route, request) { route.continue(headers: request.headers.merge("accept" => IMAGE_ACCEPT)) })
          response = tab.goto(url)
          [response.status, response.body.b]
        ensure
          tab.close
        end
      end

      IMAGE_ACCEPT = "image/png,image/jpeg,image/*;q=0.8,*/*;q=0.5".freeze

      FETCH_TEXT_JS = <<~JS.freeze
        async (url) => {
          const r = await fetch(url, { credentials: "include" });
          return { status: r.status, body: await r.text() };
        }
      JS
    end

    module_function

    # Open a visible browser on the login page and wait for the human to sign
    # in. Returns the account's display name once a session cookie exists and
    # the API confirms it. Raises LoginAborted if the window is closed first or
    # +timeout+ seconds pass.
    def login(profile_dir:, io: $stdout, timeout: 600)
      with_context(profile_dir: profile_dir, headless: false) do |context, page|
        page.goto(LOGIN_URL)
        io.puts "Log into Patreon in the browser window. Waiting for the session (up to #{timeout / 60} min)…"

        deadline = Time.now + timeout
        until session_cookie?(context)
          raise LoginAborted, "the browser window was closed before logging in" if page.closed?
          raise LoginAborted, "timed out after #{timeout}s waiting for a Patreon login" if Time.now > deadline

          sleep 1
        end

        name = current_user_name(Transport.new(page, page.title))
        raise LoginAborted, "a session cookie appeared but Patreon does not report a logged-in user" if name.nil?

        name
      end
    rescue Playwright::Error => e
      # Closing the window mid-poll surfaces as a driver error rather than a
      # closed page; to the user it is the same thing.
      raise LoginAborted, "the browser was closed before logging in (#{e.message.lines.first.to_s.strip})"
    end

    # Yield a Transport bound to a page on patreon.com, using the saved
    # profile. Headless by default; the headful fallback exists in case
    # Cloudflare starts challenging the headless build.
    def open(profile_dir:, headless: true)
      with_context(profile_dir: profile_dir, headless: headless) do |_context, page|
        page.goto(HOME_URL)
        yield Transport.new(page, page.title)
      end
    end

    # The logged-in account's display name, or nil when the profile has no
    # valid session. A Cloudflare challenge is reported as such rather than
    # as "not logged in", since re-logging in would not fix it.
    def status(profile_dir:)
      open(profile_dir: profile_dir) do |transport|
        if transport.landing_title.to_s =~ /just a moment/i
          raise PatreonClient::AuthRequired, "Patreon served a Cloudflare challenge to the headless browser; try `patreon login` to refresh the profile"
        end
        current_user_name(transport)
      end
    end

    # Write the Patreon cookies of the saved profile to +path+ so the login
    # can be carried to a machine that has no display to run #login on. The
    # file is a credential: it is created readable by the owner only.
    def export(profile_dir:, path:)
      cookies = open(profile_dir: profile_dir) do |transport|
        raise PatreonClient::AuthRequired, "the saved profile is not logged in; run 'peasant_path patreon login' first" if current_user_name(transport).nil?
        transport.patreon_cookies
      end
      File.open(path, File::WRONLY | File::CREAT | File::TRUNC, 0o600) do |f|
        f.write(JSON.pretty_generate("cookies" => cookies))
      end
      cookies.size
    end

    # Load cookies written by #export into the profile and confirm Patreon
    # accepts them. Returns the account's display name.
    def import(profile_dir:, path:)
      cookies = JSON.parse(File.read(path)).fetch("cookies")
      raise LoginAborted, "#{path} holds no Patreon cookies" if cookies.empty?

      with_context(profile_dir: profile_dir, headless: true) do |context, page|
        context.add_cookies(cookies.map { |c| c.transform_keys(&:to_sym) })
        page.goto(HOME_URL)
        name = current_user_name(Transport.new(page, page.title))
        raise LoginAborted, "Patreon did not accept the imported cookies; export a fresh file from a logged-in profile" if name.nil?
        name
      end
    end

    # Forget the browser profile (and with it the Patreon session). Returns
    # whether there was one to remove.
    def logout(profile_dir:)
      existed = File.directory?(profile_dir)
      FileUtils.rm_rf(profile_dir)
      existed
    end

    # Remove crash leftovers that would stop Chromium from opening the
    # profile; refuse if the process that holds the lock is still alive.
    def clear_stale_locks(profile_dir)
      lock = File.join(profile_dir, "SingletonLock")
      if File.symlink?(lock)
        pid = File.readlink(lock).split("-").last.to_i
        raise Busy, "another peasant_path process is using the Patreon browser profile (pid #{pid})" if pid.positive? && process_alive?(pid)
      end
      LOCK_FILES.each { |name| FileUtils.rm_f(File.join(profile_dir, name)) }
    end

    def process_alive?(pid)
      Process.kill(0, pid)
      true
    rescue Errno::ESRCH
      false
    rescue Errno::EPERM
      true
    end

    def with_context(profile_dir:, headless:)
      Browser.with_playwright do |playwright|
        FileUtils.mkdir_p(profile_dir)
        clear_stale_locks(profile_dir)

        options = Browser.launch_options(headless: headless)
        options[:userAgent] = Browser.headed_user_agent(playwright) if headless
        playwright.chromium.launch_persistent_context(profile_dir, **options) do |context|
          page = context.pages.first || context.new_page
          yield context, page
        end
      end
    end

    def session_cookie?(context)
      context.cookies.any? do |cookie|
        cookie["name"] == "session_id" && cookie["domain"].to_s.end_with?("patreon.com")
      end
    end

    def current_user_name(transport)
      status, body = transport.get_json(CURRENT_USER_URL)
      return nil unless status == 200

      body&.dig("data", "attributes", "full_name")
    end
  end
end
