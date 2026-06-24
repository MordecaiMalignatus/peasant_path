require "peasant_path"

RSpec.describe PeasantPath::Scheduler do
  describe ".mode" do
    it "honours an explicit 'off' override" do
      expect(described_class.mode(env: { "PEASANT_PATH_SCHEDULER" => "off" })).to eq :off
    end

    it "honours an explicit 'internal' override" do
      expect(described_class.mode(env: { "PEASANT_PATH_SCHEDULER" => "internal" })).to eq :internal
    end

    it "honours an explicit 'external' override" do
      expect(described_class.mode(env: { "PEASANT_PATH_SCHEDULER" => "external" })).to eq :external
    end

    it "is external when a systemd timer is active" do
      allow(described_class).to receive(:systemd_timer_active?).and_return(true)
      expect(described_class.mode(env: {})).to eq :external
    end

    it "falls back to internal when no systemd timer is active" do
      allow(described_class).to receive(:systemd_timer_active?).and_return(false)
      expect(described_class.mode(env: {})).to eq :internal
    end

    it "raises on unknown override values" do
      expect {
        described_class.mode(env: { "PEASANT_PATH_SCHEDULER" => "sometimes" })
      }.to raise_error(ArgumentError, /Unknown PEASANT_PATH_SCHEDULER/)
    end
  end

  describe ".host_scheduler" do
    it "is :systemd when booted under systemd" do
      allow(described_class).to receive(:systemd_available?).and_return(true)
      expect(described_class.host_scheduler).to eq :systemd
    end

    it "is :launchd on macOS without systemd" do
      allow(described_class).to receive(:systemd_available?).and_return(false)
      allow(described_class).to receive(:macos?).and_return(true)
      expect(described_class.host_scheduler).to eq :launchd
    end

    it "falls back to :internal when no external scheduler is available" do
      allow(described_class).to receive(:systemd_available?).and_return(false)
      allow(described_class).to receive(:macos?).and_return(false)
      expect(described_class.host_scheduler).to eq :internal
    end
  end

  describe ".systemd_timer_active?" do
    it "is false when not booted under systemd" do
      allow(described_class).to receive(:systemd_available?).and_return(false)
      expect(described_class.systemd_timer_active?).to be false
    end
  end

  describe ".systemd_units" do
    subject(:units) do
      described_class.systemd_units(
        exec_serve: "/ruby /pr serve --bind 0.0.0.0 --port 9000",
        exec_pull: "/ruby /pr refresh --throttle",
        interval_hours: 4,
      )
    end

    it "generates the three expected unit files" do
      expect(units.keys).to contain_exactly(
        "peasant-path-web.service",
        "peasant-path-pull.service",
        "peasant-path-pull.timer"
      )
    end

    it "points the web service at serve and restarts it" do
      web = units["peasant-path-web.service"]
      expect(web).to include("ExecStart=/ruby /pr serve --bind 0.0.0.0 --port 9000")
      expect(web).to include("Restart=always")
    end

    it "points the pull service at refresh as a oneshot" do
      pull = units["peasant-path-pull.service"]
      expect(pull).to include("Type=oneshot")
      expect(pull).to include("ExecStart=/ruby /pr refresh --throttle")
    end

    it "sets the timer interval and makes it persistent" do
      timer = units["peasant-path-pull.timer"]
      expect(timer).to include("OnUnitActiveSec=4h")
      expect(timer).to include("Persistent=true")
    end
  end

  describe ".launchd_plist" do
    it "generates the launchd job for refresh" do
      plist = described_class.launchd_plist(
        ruby_path: "/ruby",
        script_path: "/bin/peasant_path",
        interval_seconds: 3600,
        log_dir: "/logs",
      )

      expect(plist).to include("<string>/ruby</string>")
      expect(plist).to include("<string>/bin/peasant_path</string>")
      expect(plist).to include("<string>refresh</string>")
      expect(plist).to include("<integer>3600</integer>")
      expect(plist).to include("<string>/logs/peasant_path.log</string>")
    end
  end
end
