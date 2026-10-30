require "peasant_path"
require "peasant_path/browser"
require "tmpdir"
require "stringio"
require "fileutils"

RSpec.describe PeasantPath::Browser do
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

  describe ".launch_options" do
    it "hides the automation marker Cloudflare challenges on" do
      expect(described_class.launch_options(headless: true)[:args]).to include("--disable-blink-features=AutomationControlled")
    end
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
        # An empty driver_dir keeps a real `browser install` on this machine
        # from taking precedence.
        expect(described_class.cli_path(driver_dir: File.join(tmpdir, "no-driver"))).to eq local
        expect(described_class.cli_path(driver_dir: File.join(tmpdir, "no-driver"))).not_to eq on_path
      end
    end

    it "raises NotInstalled with install instructions when nothing is found" do
      with_env("PEASANT_PATH_PLAYWRIGHT_CLI" => nil, "PATH" => tmpdir) do
        allow(File).to receive(:exist?).and_call_original
        allow(File).to receive(:exist?).with(a_string_ending_with("node_modules/.bin/playwright-core")).and_return(false)
        expect { described_class.cli_path }.to raise_error(described_class::NotInstalled, /peasant_path browser install.*PEASANT_PATH_PLAYWRIGHT_CLI/m)
      end
    end

    it "prefers the state-directory driver installed by `browser install` over the checkout and PATH" do
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
end
