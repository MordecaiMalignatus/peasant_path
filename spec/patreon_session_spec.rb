require "peasant_path"
require "peasant_path/patreon_session"
require "tmpdir"
require "stringio"
require "fileutils"

RSpec.describe PeasantPath::PatreonSession do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmpdir) }

  # Stub out the env and PATH so discovery is deterministic regardless of what
  # the developer machine happens to have installed.
  def with_env(overrides)
    saved = overrides.to_h { |key, _| [key, ENV[key]] }
    overrides.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
    yield
  ensure
    saved.each { |key, value| value.nil? ? ENV.delete(key) : ENV[key] = value }
  end

  def executable(dir, name)
    path = File.join(dir, name)
    File.write(path, "#!/bin/sh\n")
    File.chmod(0o755, path)
    path
  end

  describe ".cli_path" do
    it "prefers PEASANT_PATH_PLAYWRIGHT_CLI when it points at an existing file" do
      override = executable(tmpdir, "override-cli")
      with_env("PEASANT_PATH_PLAYWRIGHT_CLI" => override) do
        expect(described_class.cli_path).to eq override
      end
    end

    it "ignores an override that does not exist and falls through to PATH" do
      on_path = executable(tmpdir, "playwright-core")
      with_env("PEASANT_PATH_PLAYWRIGHT_CLI" => File.join(tmpdir, "missing"), "PATH" => tmpdir) do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(a_string_ending_with("node_modules/.bin/playwright-core")).and_return(false)
        expect(described_class.cli_path).to eq on_path
      end
    end

    it "checks the checkout-local node_modules before PATH" do
      on_path = executable(tmpdir, "playwright-core")
      local = File.expand_path("../node_modules/.bin/playwright-core", __dir__)
      with_env("PEASANT_PATH_PLAYWRIGHT_CLI" => nil, "PATH" => tmpdir) do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(local).and_return(true)
        # An empty driver_dir keeps a real `patreon install` on this machine
        # from taking precedence.
        expect(described_class.cli_path(driver_dir: File.join(tmpdir, "no-driver"))).to eq local
        expect(described_class.cli_path(driver_dir: File.join(tmpdir, "no-driver"))).not_to eq on_path
      end
    end

    it "raises NotInstalled with install instructions when nothing is found" do
      with_env("PEASANT_PATH_PLAYWRIGHT_CLI" => nil, "PATH" => tmpdir) do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(a_string_ending_with("node_modules/.bin/playwright-core")).and_return(false)
        expect { described_class.cli_path }.to raise_error(described_class::NotInstalled, /peasant_path patreon install.*PEASANT_PATH_PLAYWRIGHT_CLI/m)
      end
    end

    it "prefers the state-directory driver installed by `patreon install` over the checkout and PATH" do
      driver_dir = File.join(tmpdir, "driver")
      FileUtils.mkdir_p(File.join(driver_dir, "node_modules", ".bin"))
      installed = executable(File.join(driver_dir, "node_modules", ".bin"), "playwright-core")
      executable(tmpdir, "playwright-core")
      with_env("PEASANT_PATH_PLAYWRIGHT_CLI" => nil, "PATH" => tmpdir) do
        expect(described_class.cli_path(driver_dir: driver_dir)).to eq installed
      end
    end
  end

  describe ".install" do
    it "refuses without npm and says how to get it" do
      with_env("PATH" => tmpdir) do
        expect { described_class.install(driver_dir: File.join(tmpdir, "driver"), io: StringIO.new) }.to raise_error(described_class::NotInstalled, /npm not found.*nodejs\.org/m)
      end
    end

    it "npm-installs the pinned driver into the directory, then downloads Chromium with it" do
      executable(tmpdir, "npm")
      driver_dir = File.join(tmpdir, "driver")
      calls = []
      runner = lambda do |argv|
        calls << argv
        if argv.first == "npm"
          FileUtils.mkdir_p(File.join(driver_dir, "node_modules", ".bin"))
          executable(File.join(driver_dir, "node_modules", ".bin"), "playwright-core")
        end
        true
      end

      cli = with_env("PATH" => tmpdir) { described_class.install(driver_dir: driver_dir, io: StringIO.new, runner: runner) }

      expect(cli).to eq File.join(driver_dir, "node_modules", ".bin", "playwright-core")
      expect(calls.first).to eq ["npm", "install", "--prefix", driver_dir, "--no-fund", "--no-audit", "playwright-core@#{Playwright::COMPATIBLE_PLAYWRIGHT_VERSION}"]
      expect(calls.last).to eq [cli, "install", "--no-shell", "chromium"]
    end
  end

  describe ".logout" do
    it "removes the profile directory and reports that it existed" do
      profile = File.join(tmpdir, "profile")
      FileUtils.mkdir_p(File.join(profile, "Default"))
      File.write(File.join(profile, "Default", "Cookies"), "x")

      expect(described_class.logout(profile_dir: profile)).to be true
      expect(File.exist?(profile)).to be false
    end

    it "reports false when there was no profile" do
      expect(described_class.logout(profile_dir: File.join(tmpdir, "nope"))).to be false
    end
  end

  describe ".clear_stale_locks" do
    let(:profile) { File.join(tmpdir, "profile") }

    before do
      FileUtils.mkdir_p(profile)
      %w[SingletonSocket SingletonCookie Preferences].each { |name| File.write(File.join(profile, name), "") }
    end

    it "deletes Chromium's singleton lock files and nothing else" do
      File.write(File.join(profile, "SingletonLock"), "")

      described_class.clear_stale_locks(profile)

      expect(Dir.children(profile)).to eq ["Preferences"]
    end

    it "removes a lock left by a process that no longer exists" do
      # 2**22 - 1 is above the default pid ceiling on both Linux and macOS.
      File.symlink("example.local-#{2 ** 22 - 1}", File.join(profile, "SingletonLock"))

      described_class.clear_stale_locks(profile)

      expect(Dir.children(profile)).to eq ["Preferences"]
    end

    it "refuses to touch a lock held by a live process" do
      File.symlink("example.local-#{Process.pid}", File.join(profile, "SingletonLock"))

      expect { described_class.clear_stale_locks(profile) }.to raise_error(described_class::Busy, /pid #{Process.pid}/)
      expect(Dir.children(profile).sort).to eq %w[Preferences SingletonCookie SingletonLock SingletonSocket]
    end
  end

  describe ".session_cookie?" do
    it "matches a session_id cookie on a patreon.com domain using string keys" do
      context = double(cookies: [{ "name" => "__cf_bm", "domain" => ".patreon.com" }, { "name" => "session_id", "domain" => "www.patreon.com" }])
      expect(described_class.session_cookie?(context)).to be true
    end

    it "rejects a session_id cookie from another site" do
      context = double(cookies: [{ "name" => "session_id", "domain" => "example.com" }])
      expect(described_class.session_cookie?(context)).to be false
    end
  end

  describe ".current_user_name" do
    it "returns the display name on a 200" do
      transport = double(get_json: [200, { "data" => { "attributes" => { "full_name" => "Reader" } } }])
      expect(described_class.current_user_name(transport)).to eq "Reader"
    end

    it "returns nil when the API says login is required" do
      transport = double(get_json: [401, { "errors" => [] }])
      expect(described_class.current_user_name(transport)).to be_nil
    end
  end

  # Needs a real Chromium plus a profile that already holds a Patreon login;
  # excluded by default via .rspec. Run with:
  #   PEASANT_PATH_PLAYWRIGHT_CLI=... PEASANT_PATH_TEST_PROFILE=... bundle exec rspec spec/patreon_session_spec.rb --tag browser
  describe ".open", :browser do
    let(:source_profile) { ENV.fetch("PEASANT_PATH_TEST_PROFILE") }
    let(:profile) { File.join(tmpdir, "profile") }

    before { FileUtils.cp_r(source_profile, profile) }

    it "reaches Patreon logged in from a headless browser and can fetch JSON and bytes" do
      described_class.open(profile_dir: profile) do |transport|
        expect(transport.landing_title).to eq "Home | Patreon"

        status, me = transport.get_json("https://www.patreon.com/api/current_user?json-api-version=1.0")
        expect(status).to eq 200
        expect(me.dig("data", "type")).to eq "user"

        status, collection = transport.get_json("https://www.patreon.com/api/collection/1522125?json-api-version=1.0")
        expect(status).to eq 200
        thumbnail = collection.dig("data", "attributes", "thumbnail", "url")
        expect(thumbnail).to start_with("https://")

        status, bytes = transport.get_bytes(thumbnail)
        expect(status).to eq 200
        expect(bytes.b[0, 4]).to eq "\x89PNG".b
      end
    end
  end
end
