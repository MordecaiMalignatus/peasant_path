require "fileutils"

module PeasantPath
  # Locating, installing and launching the Playwright-driven Chromium that
  # every source fetches through. RoyalRoad sits behind Anubis and Patreon
  # behind Cloudflare; both turn away plain HTTP clients, so requests are made
  # from inside a real browser page instead.
  #
  # `playwright` is required lazily inside the methods that need it so that
  # loading peasant_path (the test suite, `list`, the web UI's boot) never
  # needs Node.
  module Browser
    class NotInstalled < StandardError; end

    INSTALL_HINT = "Pulling stories needs Node and Playwright's Chromium. Run `peasant_path browser install` " \
                   "(needs npm), or point PEASANT_PATH_PLAYWRIGHT_CLI at a playwright-core executable.".freeze

    module_function

    # Locate the playwright-core CLI the Ruby client drives. Checked in order:
    # an explicit env override, the state-directory install made by
    # `browser install`, a checkout-local npm install, then PATH.
    def cli_path(driver_dir: Library::BROWSER_DRIVER_DIR)
      candidates = [
        ENV["PEASANT_PATH_PLAYWRIGHT_CLI"],
        driver_cli(driver_dir),
        File.expand_path("../../node_modules/.bin/playwright-core", __dir__),
        which("playwright-core"),
      ].compact.reject(&:empty?)

      found = candidates.find { |path| File.exist?(path) }
      raise NotInstalled, "playwright-core not found. #{INSTALL_HINT}" if found.nil?

      found
    end

    # Install the Node driver (pinned to the version this gem's Ruby client
    # speaks) and Chromium under +driver_dir+, using npm. Returns the path of
    # the installed CLI. The system libraries Chromium needs on Linux require
    # root, so that step is printed as an instruction rather than run.
    def install(driver_dir: Library::BROWSER_DRIVER_DIR, io: $stdout, runner: method(:run!))
      require "playwright"
      raise NotInstalled, "npm not found on PATH. Install Node.js (https://nodejs.org) and run `peasant_path browser install` again." if which("npm").nil?

      version = Playwright::COMPATIBLE_PLAYWRIGHT_VERSION
      FileUtils.mkdir_p(driver_dir)
      io.puts "Installing playwright-core #{version} into #{driver_dir}…"
      runner.call(["npm", "install", "--prefix", driver_dir, "--no-fund", "--no-audit", "playwright-core@#{version}"])
      cli = driver_cli(driver_dir)
      raise NotInstalled, "npm finished but #{cli} is missing" unless File.exist?(cli)

      io.puts "Downloading Chromium…"
      runner.call([cli, "install", "--no-shell", "chromium"])
      if RUBY_PLATFORM.include?("linux")
        io.puts "Chromium needs system libraries on Linux; if pulls fail to launch a browser run:"
        io.puts "  sudo #{cli} install-deps chromium"
      end
      cli
    end

    def driver_cli(driver_dir)
      File.join(driver_dir, "node_modules", ".bin", "playwright-core")
    end

    def run!(argv)
      system(*argv) or raise NotInstalled, "command failed: #{argv.join(" ")}"
    end

    # Yield a running Playwright instance driving the located CLI.
    def with_playwright
      require "playwright"

      cli = cli_path
      Playwright.create(playwright_cli_executable_path: cli) { |playwright| yield playwright }
    end

    # Launch options for Playwright's bundled Chromium.
    def launch_options(headless:)
      { headless: headless, channel: "chromium" }
    end

    # New-headless Chromium announces itself as "HeadlessChrome/<ver>", which
    # is enough for Cloudflare to serve an interstitial. The string is
    # otherwise identical to the headed one, so read it from a throwaway
    # browser and drop the "Headless" marker. Cached per process: the browser
    # binary does not change underneath us.
    def headed_user_agent(playwright)
      @headed_user_agent ||= begin
          browser = playwright.chromium.launch(**launch_options(headless: true))
          begin
            ua = browser.new_page.evaluate("() => navigator.userAgent")
          ensure
            browser.close
          end
          ua.sub("HeadlessChrome/", "Chrome/")
        end
    end

    def which(cmd)
      ENV.fetch("PATH", "").split(File::PATH_SEPARATOR).each do |dir|
        candidate = File.join(dir, cmd)
        return candidate if File.executable?(candidate) && !File.directory?(candidate)
      end
      nil
    end
  end
end
