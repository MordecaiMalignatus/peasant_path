require "peasant_road"

RSpec.describe PeasantRoad::Scheduler do
  describe ".mode" do
    it "honours an explicit 'off' override" do
      expect(described_class.mode(env: { "PEASANT_ROAD_SCHEDULER" => "off" })).to eq :off
    end

    it "honours an explicit 'internal' override" do
      expect(described_class.mode(env: { "PEASANT_ROAD_SCHEDULER" => "internal" })).to eq :internal
    end

    it "honours an explicit 'external' override" do
      expect(described_class.mode(env: { "PEASANT_ROAD_SCHEDULER" => "external" })).to eq :external
    end

    it "is external when a systemd timer is active" do
      allow(described_class).to receive(:systemd_timer_active?).and_return(true)
      expect(described_class.mode(env: {})).to eq :external
    end

    it "falls back to internal when no systemd timer is active" do
      allow(described_class).to receive(:systemd_timer_active?).and_return(false)
      expect(described_class.mode(env: {})).to eq :internal
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
        "peasant-road-web.service",
        "peasant-road-pull.service",
        "peasant-road-pull.timer"
      )
    end

    it "points the web service at serve and restarts it" do
      web = units["peasant-road-web.service"]
      expect(web).to include("ExecStart=/ruby /pr serve --bind 0.0.0.0 --port 9000")
      expect(web).to include("Restart=always")
    end

    it "points the pull service at refresh as a oneshot" do
      pull = units["peasant-road-pull.service"]
      expect(pull).to include("Type=oneshot")
      expect(pull).to include("ExecStart=/ruby /pr refresh --throttle")
    end

    it "sets the timer interval and makes it persistent" do
      timer = units["peasant-road-pull.timer"]
      expect(timer).to include("OnUnitActiveSec=4h")
      expect(timer).to include("Persistent=true")
    end
  end
end
