require "rbconfig"
require "cgi"

module PeasantPath
  # Decides how the auto-pull happens and, in the in-process fallback case, runs
  # it. systemd is the preferred ("external") mechanism; when it isn't driving
  # the pull we run an in-process loop instead.
  class Scheduler
    TIMER_UNIT = "peasant-path-pull.timer".freeze
    DEFAULT_INTERVAL_HOURS = 6
    # Match systemd's OnBootSec=15min: pull once shortly after boot rather than
    # waiting a full interval, so a freshly started daemon isn't idle for hours.
    BOOT_DELAY_SECONDS = 15 * 60

    # :off      — scheduling explicitly disabled
    # :external — a systemd timer is active; this process must not self-schedule
    # :internal — run the in-process loop
    def self.mode(env: ENV)
      case env["PEASANT_PATH_SCHEDULER"]
      when "off" then :off
      when "internal" then :internal
      when "external" then :external
      when nil, "" then systemd_timer_active? ? :external : :internal
      else
        raise ArgumentError, "Unknown PEASANT_PATH_SCHEDULER value: #{env["PEASANT_PATH_SCHEDULER"]}"
      end
    end

    # Which external scheduler this host can install. systemd is Linux's
    # mechanism, launchd is macOS's; anything else has no external scheduler and
    # relies on serve's in-process loop, so we report :internal.
    def self.host_scheduler
      return :systemd if systemd_available?
      return :launchd if macos?
      :internal
    end

    def self.macos?
      RbConfig::CONFIG["host_os"].include?("darwin")
    end

    # path is the PATH the job runs with. launchd and systemd start jobs with
    # a bare system PATH, and the browser driver finds Node through PATH, so
    # the installing shell's PATH (with a Node from mise, nvm or Homebrew) is
    # written into the job.
    def self.launchd_plist(ruby_path:, script_path:, interval_seconds:, log_dir:, path:)
      x = ->(text) { CGI.escapeHTML(text.to_s) }
      <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>com.peasant_path.pull</string>
          <key>ProgramArguments</key>
          <array>
            <string>#{x.(ruby_path)}</string>
            <string>#{x.(script_path)}</string>
            <string>refresh</string>
            <string>--throttle</string>
          </array>
          <key>EnvironmentVariables</key>
          <dict>
            <key>PATH</key>
            <string>#{x.(path)}</string>
          </dict>
          <key>StartInterval</key>
          <integer>#{interval_seconds}</integer>
          <key>RunAtLoad</key>
          <false/>
          <key>StandardOutPath</key>
          <string>#{x.("#{log_dir}/peasant_path.log")}</string>
          <key>StandardErrorPath</key>
          <string>#{x.("#{log_dir}/peasant_path.error.log")}</string>
        </dict>
        </plist>
      XML
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

    # One word of an ExecStart= or Environment= line, quoted so spaces survive.
    # Inside quotes systemd reads backslash escapes, and it expands %
    # specifiers everywhere, so both are escaped.
    def self.systemd_quote(word)
      escaped = word.to_s.gsub("\\") { "\\\\" }.gsub('"') { '\\"' }.gsub("%") { "%%" }
      %("#{escaped}")
    end

    # An ExecStart= command line from its words.
    def self.systemd_command(*words)
      words.map { |word| systemd_quote(word) }.join(" ")
    end

    # Pure generator for the three --user units. Returns { filename => content }.
    # path is the PATH both services run with, as for launchd_plist.
    def self.systemd_units(exec_serve:, exec_pull:, path:, interval_hours: DEFAULT_INTERVAL_HOURS)
      environment = "Environment=#{systemd_quote("PATH=#{path}")}"
      {
        "peasant-path-web.service" => <<~UNIT,
          [Unit]
          Description=Peasant Path web interface
          After=network.target

          [Service]
          #{environment}
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
          #{environment}
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

    def initialize(library:, jobs:, interval_seconds:, boot_delay_seconds: BOOT_DELAY_SECONDS)
      @library = library
      @jobs = jobs
      @interval_seconds = interval_seconds
      @boot_delay_seconds = boot_delay_seconds
    end

    # Start the in-process loop. Refreshes through the shared Jobs runner so a
    # scheduled pull never overlaps a manual "pull now" or a follow-build. Pulls
    # once after a short boot delay, then every interval thereafter.
    def start
      @thread = Thread.new do
        sleep @boot_delay_seconds
        loop do
          @jobs.run { @library.refresh(throttle: true) }
          sleep @interval_seconds
        end
      end
    end

    def stop
      @thread&.kill
    end
  end
end
