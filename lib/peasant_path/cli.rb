require "uri"
require "rbconfig"
require "time"
require "fileutils"
require "thor"

module PeasantPath
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    def initialize(*args)
      super
      @repo = DiskRepository.new(Library::DEFAULT_ROOT)
      @library = Library.new(repo: @repo)
      @config = Config.from_config_file(@repo.read_config_file)
    end

    desc "add URL [URL...]", "Follow one or more RoyalRoad stories by URL"
    option :name, type: :string, aliases: "-n", desc: "Override display name for the story"

    def add(*urls)
      if urls.empty?
        raise Thor::Error, "Please provide at least one RoyalRoad URL"
      end

      urls.each do |url|
        result = @library.follow(url, name: options[:name])
        if result[:followed]
          puts "Followed #{result[:fic].display_title}"
        else
          puts "Already following this fic, skipping."
        end
      end
    rescue Library::InvalidURL => e
      raise Thor::Error, e.message
    end

    desc "unfollow FIC_ID", "Stop following a story while keeping downloaded files"

    def unfollow(fic_id)
      if @library.unfollow(fic_id)
        puts "Unfollowed #{fic_id}. Downloaded files were left on disk."
      else
        puts "Not following #{fic_id}."
      end
    end

    desc "pull", "Pull new chapters for all followed stories"
    option :throttle, type: :boolean, default: false, desc: "Add 5-15s random delay between chapter downloads to avoid rate limiting"

    def pull
      render_pull_results(@library.pull_all(throttle: options[:throttle]))
    end

    desc "refresh", "Pull new chapters and rebuild the stories that changed"
    option :throttle, type: :boolean, default: false, desc: "Add 5-15s random delay between chapter downloads to avoid rate limiting"

    def refresh
      render_pull_results(@library.refresh(throttle: options[:throttle]))
    end

    desc "report", "Show what's new per story over a recent time window"
    option :hours, type: :numeric, aliases: "-h", default: 48, desc: "How many hours back to look"

    def report
      all_entries = @repo.read_pull_log
      if all_entries.empty?
        puts "No pull history found. Run 'pull' first."
        return
      end

      report = @library.report(hours: options[:hours])
      active = report[:active]
      quiet = report[:quiet]

      active.each do |_, data|
        puts data[:title]
        data[:runs].select { |r| r[:new_chapters].any? || r[:error] }.each do |run|
          if run[:error]
            puts "  ERROR: #{run[:error]}"
          else
            run[:new_chapters].each { |t| puts "  #{set_color("+ #{t}", :green, :bold)}" }
          end
        end
      end

      puts "No new chapters: #{quiet.map { |_, d| d[:title] }.join(", ")}" unless quiet.empty?
    end

    desc "schedule", "Install a launchd job to refresh (pull + rebuild) automatically (macOS only)"
    option :interval, type: :numeric, aliases: "-i", default: 6, desc: "Pull interval in hours"

    def schedule
      interval_hours = options[:interval]
      interval_seconds = (interval_hours * 3600).to_i
      ruby_path = RbConfig.ruby
      script_path = File.expand_path($PROGRAM_NAME)
      plist_path = File.expand_path("~/Library/LaunchAgents/com.peasant_path.pull.plist")
      log_dir = File.expand_path("~/Library/Logs")

      plist = Scheduler.launchd_plist(
        ruby_path: ruby_path,
        script_path: script_path,
        interval_seconds: interval_seconds,
        log_dir: log_dir,
      )

      File.write(plist_path, plist)
      interval_label = interval_hours == 1 ? "every hour" : "every #{interval_hours} hours"
      puts "Wrote launchd plist (#{interval_label}) to #{plist_path}"
      puts "Load with:"
      puts "  launchctl load #{plist_path}"
    end

    desc "serve", "Start the web interface"
    option :port, type: :numeric, default: 4567, desc: "Port to bind"
    option :bind, type: :string, default: "127.0.0.1", desc: "Address to bind"

    def serve
      require "peasant_path/web"
      Web.set(:bind, options[:bind])
      Web.set(:port, options[:port])
      Web.start_scheduler!
      Web.run!
    end

    desc "build [FIC_ID...]", "Build an EPUB for one or more followed stories (interactive selector if no IDs given)"

    def build(*fic_ids)
      if fic_ids.empty?
        fic_ids = select_fics_with_fzf
        return if fic_ids.empty?
      end

      fic_ids.each do |fid|
        puts "Building EPUB for fic ID #{fid}..."
        f = Fic.from_disk(fid, @repo)
        @library.pull_fic(f)
        f.book.build_all(Dir.pwd)
      end
    end

    desc "install", "Install systemd --user units for the web server and auto-pull timer (Linux)"
    option :interval, type: :numeric, aliases: "-i", default: Scheduler::DEFAULT_INTERVAL_HOURS, desc: "Pull interval in hours"
    option :port, type: :numeric, default: 4567, desc: "Port the web server binds"
    option :bind, type: :string, default: "127.0.0.1", desc: "Address the web server binds"

    def install
      ruby_path = RbConfig.ruby
      script_path = File.expand_path($PROGRAM_NAME)
      unit_dir = File.expand_path("~/.config/systemd/user")

      units = Scheduler.systemd_units(
        exec_serve: "#{ruby_path} #{script_path} serve --bind #{options[:bind]} --port #{options[:port]}",
        exec_pull: "#{ruby_path} #{script_path} refresh --throttle",
        interval_hours: options[:interval],
      )

      FileUtils.mkdir_p(unit_dir)
      units.each do |filename, content|
        File.write("#{unit_dir}/#{filename}", content)
        puts "Wrote #{unit_dir}/#{filename}"
      end

      puts ""
      puts "Enable and start with:"
      puts "  systemctl --user daemon-reload"
      puts "  systemctl --user enable --now peasant-path-web.service peasant-path-pull.timer"
      puts "  loginctl enable-linger #{ENV["USER"]}   # keep user units running without an active login"
    end

    private

    def render_pull_results(results)
      quiet = []

      results.each do |r|
        f = r[:fic]
        if r[:error]
          puts f.display_title
          puts "  ERROR: #{r[:error]}"
        elsif r[:new_chapters].any?
          puts f.display_title
          r[:new_chapters].each { |c| puts "  #{set_color("+ #{c.chapter_title}", :green, :bold)}" }
        else
          quiet << f.display_title
        end
      end

      puts "No new chapters: #{quiet.join(", ")}" unless quiet.empty?
    end

    def select_fics_with_fzf
      fics = @config.followed_stories.map { |fic_id| Fic.from_disk(fic_id, @repo) }
      input = fics.map { |f| "#{f.display_title}\t#{f.fic_id}" }.join("\n")

      output = IO.popen(["fzf", "--multi", "--with-nth=1", "--delimiter=\t"], "r+") do |io|
        io.write(input)
        io.close_write
        io.read
      end

      return [] if output.nil? || output.strip.empty?
      output.strip.split("\n").map { |line| line.split("\t", 2).last }
    rescue Errno::ENOENT
      raise Thor::Error, "fzf not found. Install fzf or provide fic IDs directly."
    end
  end
end
