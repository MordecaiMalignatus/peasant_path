require "rbconfig"

module PeasantPath
  # Decides how the auto-pull happens and, in the in-process fallback case, runs
  # it. systemd is the preferred ("external") mechanism; when it isn't driving
  # the pull we run an in-process loop instead.
  class Scheduler
    TIMER_UNIT = "peasant-path-pull.timer".freeze
    DEFAULT_INTERVAL_HOURS = 6

    # :off      — scheduling explicitly disabled
    # :external — a systemd timer is active; this process must not self-schedule
    # :internal — run the in-process loop
    def self.mode(env: ENV)
      case env["PEASANT_PATH_SCHEDULER"]
      when "off" then :off
      when "internal" then :internal
      when "external" then :external
      else
        systemd_timer_active? ? :external : :internal
      end
    end

    # True only when booted under systemd and the pull timer is active, so we
    # never double-pull alongside the systemd job.
    def self.systemd_timer_active?
      return false unless systemd_available?
      system("systemctl", "--user", "is-active", "--quiet", TIMER_UNIT,
             out: File::NULL, err: File::NULL) || false
    end

    def self.systemd_available?
      File.directory?("/run/systemd/system")
    end

    # Pure generator for the three --user units. Returns { filename => content }.
    def self.systemd_units(exec_serve:, exec_pull:, interval_hours: DEFAULT_INTERVAL_HOURS)
      {
        "peasant-path-web.service" => <<~UNIT,
          [Unit]
          Description=Peasant Path web interface
          After=network.target

          [Service]
          ExecStart=#{exec_serve}
          Restart=always

          [Install]
          WantedBy=default.target
        UNIT
        "peasant-path-pull.service" => <<~UNIT,
          [Unit]
          Description=Peasant Path chapter pull and rebuild

          [Service]
          Type=oneshot
          ExecStart=#{exec_pull}
        UNIT
        "peasant-path-pull.timer" => <<~UNIT,
          [Unit]
          Description=Periodic Peasant Path pull

          [Timer]
          OnBootSec=15min
          OnUnitActiveSec=#{interval_hours}h
          Persistent=true

          [Install]
          WantedBy=timers.target
        UNIT
      }
    end

    def initialize(library:, jobs:, interval_seconds:)
      @library = library
      @jobs = jobs
      @interval_seconds = interval_seconds
    end

    # Start the in-process loop. Refreshes through the shared Jobs runner so a
    # scheduled pull never overlaps a manual "pull now" or a follow-build.
    def start
      @thread = Thread.new do
        loop do
          sleep @interval_seconds
          @jobs.run { @library.refresh(throttle: true) }
        end
      end
    end

    def stop
      @thread&.kill
    end
  end
end
