require "uri"
require "rbconfig"
require "time"
require "thor"

module PeasantRoad
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    def initialize(*args)
      super
      @repo = DiskRepository.new("#{Dir.home}/.config/peasant_road")
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

    desc "pull", "Pull new chapters for all followed stories"
    option :throttle, type: :boolean, default: false, desc: "Add 5-15s random delay between chapter downloads to avoid rate limiting"

    def pull
      results = @library.pull_all(throttle: options[:throttle])
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

    desc "report", "Show what's new per story over a recent time window"
    option :hours, type: :numeric, aliases: "-h", default: 48, desc: "How many hours back to look"

    def report
      all_entries = @repo.read_pull_log
      if all_entries.empty?
        puts "No pull history found. Run 'pull' first."
        return
      end

      cutoff = Time.now - (options[:hours] * 3600)
      entries = all_entries.select { |e| Time.parse(e["timestamp"]) >= cutoff }

      fic_data = {}
      entries.each do |entry|
        time = Time.parse(entry["timestamp"])
        entry["fics"].each do |fic|
          fic_data[fic["fic_id"]] ||= { title: fic["title"], runs: [] }
          fic_data[fic["fic_id"]][:runs] << {
            time: time,
            new_chapters: fic["new_chapters"],
            error: fic["error"],
          }
        end
      end

      @config.followed_stories.each do |fic_id|
        next if fic_data.key?(fic_id)
        fic_data[fic_id] = { title: Fic.from_disk(fic_id, @repo).display_title, runs: [] }
      end

      sorted = fic_data.sort_by { |_, d| [-d[:runs].sum { |r| r[:new_chapters].length }, d[:title]] }

      active, quiet = sorted.partition { |_, d| d[:runs].any? { |r| r[:new_chapters].any? || r[:error] } }

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

    desc "schedule", "Install a launchd job to run pull automatically (macOS only)"
    option :interval, type: :numeric, aliases: "-i", default: 6, desc: "Pull interval in hours"

    def schedule
      interval_hours = options[:interval]
      interval_seconds = (interval_hours * 3600).to_i
      ruby_path = RbConfig.ruby
      script_path = File.expand_path($PROGRAM_NAME)
      plist_path = File.expand_path("~/Library/LaunchAgents/com.peasant_road.pull.plist")
      log_dir = File.expand_path("~/Library/Logs")

      plist = <<~XML
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
          <key>Label</key>
          <string>com.peasant_road.pull</string>
          <key>ProgramArguments</key>
          <array>
            <string>#{ruby_path}</string>
            <string>#{script_path}</string>
            <string>pull</string>
            <string>--throttle</string>
          </array>
          <key>StartInterval</key>
          <integer>#{interval_seconds}</integer>
          <key>RunAtLoad</key>
          <false/>
          <key>StandardOutPath</key>
          <string>#{log_dir}/peasant_road.log</string>
          <key>StandardErrorPath</key>
          <string>#{log_dir}/peasant_road.error.log</string>
        </dict>
        </plist>
      XML

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
      require "peasant_road/web"
      Web.set(:bind, options[:bind])
      Web.set(:port, options[:port])
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
        f.pull
        f.book.build_all(Dir.pwd)
      end
    end

    private

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
