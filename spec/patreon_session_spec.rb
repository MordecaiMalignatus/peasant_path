require "peasant_path"
require "peasant_path/patreon_session"
require "tmpdir"
require "stringio"
require "fileutils"

RSpec.describe PeasantPath::PatreonSession do
  let(:tmpdir) { Dir.mktmpdir }

  after { FileUtils.rm_rf(tmpdir) }

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
