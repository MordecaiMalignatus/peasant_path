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
      @rr = RoyalRoadClient.new
      @repo = DiskRepository.new("#{Dir.home}/.config/peasant_road")
      @config = Config.from_config_file(@repo.read_config_file)
    end

    desc "add URL [URL...]", "Follow one or more RoyalRoad stories by URL"
    option :name, type: :string, aliases: "-n", desc: "Override display name for the story"

    def add(*urls)
      if urls.empty?
        raise Thor::Error, "Please provide at least one RoyalRoad URL"
      end

      urls.each do |url|
        uri = URI(url)
        unless uri.host == "www.royalroad.com"
          raise Thor::Error, "'#{url}' is not a RoyalRoad URL"
        end

        fic_id = Fic.uri_to_fic_id(uri.to_s)

        unless @config.followed_stories.include?(fic_id)
          @config.followed_stories << fic_id
          fic = Fic.new(fic_id: fic_id, repository: @repo)
          fic.display_name = options[:name]
          fic.fetch_fic_info.persist_fic_info
          puts "Followed #{fic.display_title}"
        else
          puts "Already following this fic, skipping."
        end
      end

      @repo.write_config_file(@config.to_json)
    end

    desc "pull", "Pull new chapters for all followed stories"

    def pull
      puts "Pulling all followed fics..."

      fics = @config.followed_stories.map { |fic| Fic.from_disk(fic, @repo) }
      log_entry = { timestamp: Time.now.iso8601, fics: [] }

      fics.each do |f|
        puts "  Pulling #{f.display_title}..."
        begin
          new_chapters = f.pull
          log_entry[:fics] << {
            fic_id: f.fic_id,
            title: f.display_title,
            new_chapters: new_chapters.map(&:chapter_title),
          }
        rescue => e
          puts "  ERROR: #{e.message}"
          log_entry[:fics] << {
            fic_id: f.fic_id,
            title: f.display_title,
            new_chapters: [],
            error: e.message,
          }
        end
      end

      @repo.append_pull_log(log_entry)
    end

    desc "report", "Show recent automated pull history"
    option :count, type: :numeric, aliases: "-n", default: 10, desc: "Number of recent pull runs to show"

    def report
      entries = @repo.read_pull_log.last(options[:count])

      if entries.empty?
        puts "No pull history found. Run 'pull' first."
        return
      end

      entries.reverse_each do |entry|
        time = Time.parse(entry["timestamp"])
        total_new = entry["fics"].sum { |f| f["new_chapters"].length }
        fic_count = entry["fics"].length
        chapter_word = total_new == 1 ? "chapter" : "chapters"
        fic_word = fic_count == 1 ? "fic" : "fics"
        puts "#{time.strftime("%Y-%m-%d %H:%M")}  [#{fic_count} #{fic_word}, #{total_new} new #{chapter_word}]"

        entry["fics"].each do |fic|
          if fic["error"]
            puts "  %-40s ERROR: %s" % [fic["title"], fic["error"]]
          elsif fic["new_chapters"].empty?
            puts "  %-40s up to date" % fic["title"]
          else
            chapter_count = fic["new_chapters"].length
            puts "  %-40s %d new %s" % [fic["title"], chapter_count, chapter_count == 1 ? "chapter" : "chapters"]
            fic["new_chapters"].each { |t| puts "    + #{t}" }
          end
        end

        puts
      end
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

    desc "build [FIC_ID...]", "Build an EPUB for one or more followed stories (interactive selector if no IDs given)"

    def build(*fic_ids)
      if fic_ids.empty?
        fic_ids = select_fics_with_fzf
        return if fic_ids.empty?
      end

      fic_ids.each do |fid|
        puts "Building EPUB for fic ID #{fid}..."
        f = Fic.from_disk(fid, @repo)
        f.to_book.build_all("#{f.display_title}.epub")
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
