require "sinatra/base"
require "securerandom"
require "logger"

module PeasantPath
  # The web interface. A thin front-end over Library, sharing the same
  # filesystem-backed state as the CLI. No user handling — one shared library.
  class Web < Sinatra::Base
    LOGGER = Logger.new($stdout)
    LOGGER.formatter = proc do |severity, time, _progname, msg|
      "[#{time.strftime("%Y-%m-%dT%H:%M:%S")}] #{severity} #{msg}\n"
    end

    # Serializes the slow pull/build work so a manual "pull now", a
    # follow-triggered build, and the scheduler never overlap. #run spawns a
    # background thread and returns false if a job is already in flight. The
    # boolean flag — not a held mutex — is the guard, so it's always released by
    # the same thread that set it.
    class Jobs
      def initialize(logger = Logger.new($stdout))
        @logger = logger
        @lock = Mutex.new
        @busy = false
      end

      def busy?
        @lock.synchronize { @busy }
      end

      def run
        @lock.synchronize do
          return false if @busy
          @busy = true
        end

        Thread.new do
          begin
            yield
          rescue => e
            @logger.error("background job failed: #{e.class}: #{e.message}")
          ensure
            @lock.synchronize { @busy = false }
          end
        end

        true
      end
    end

    set :views, File.expand_path("../../views", __dir__)
    set :app_logger, LOGGER
    set :library, Library.new(logger: LOGGER)
    set :jobs, Jobs.new(LOGGER)
    enable :sessions
    set :session_secret, ENV.fetch("PEASANT_PATH_SESSION_SECRET") { SecureRandom.hex(64) }
    # Self-hosted, no-auth tool bound to a host the operator chooses; permit any
    # Host header rather than locking to a single name.
    set :host_authorization, { permitted_hosts: [] }

    # Start the in-process auto-pull loop, unless systemd's timer is driving it
    # (or it's disabled). Call once at boot, before run!.
    def self.start_scheduler!
      mode = Scheduler.mode
      settings.app_logger.info("scheduler mode: #{mode}")
      return unless mode == :internal

      hours = Integer(ENV.fetch("PEASANT_PATH_INTERVAL_HOURS", Scheduler::DEFAULT_INTERVAL_HOURS.to_s))
      settings.app_logger.info("starting in-process pull loop, every #{hours}h")
      Scheduler.new(
        library: settings.library,
        jobs: settings.jobs,
        interval_seconds: hours * 3600,
      ).start
    end

    after do
      settings.app_logger.info("#{request.request_method} #{request.path_info} #{response.status}")
    end

    helpers do
      def library
        settings.library
      end

      def app_logger
        settings.app_logger
      end

      def h(text)
        Rack::Utils.escape_html(text.to_s)
      end

      def flash!(message)
        session[:flash] = message
      end

      def take_flash
        session.delete(:flash)
      end

      # Build the per-story view model: chapter count plus which EPUBs are
      # actually on disk, so the index links only to downloads that exist.
      def story_rows
        repo = library.repo
        library.followed.map do |fic|
          full = repo.epub_path(fic.fic_id, "#{fic.display_title}.epub")
          volumes = fic.volumes.filter_map do |vol|
            path = repo.epub_path(fic.fic_id, "#{fic.display_title} - #{vol["title"]}.epub")
            { id: vol["id"], title: vol["title"] } if File.exist?(path)
          end
          {
            fic: fic,
            chapter_count: fic.chapters.size,
            full_available: File.exist?(full),
            volumes: volumes,
          }
        end
      end

      def followed?(fic_id)
        library.config.followed_stories.include?(fic_id)
      end

      def send_epub(fic_id, filename)
        path = library.repo.epub_path(fic_id, filename)
        halt 404, "Not built yet" unless File.exist?(path)
        send_file path, filename: File.basename(path), type: "application/epub+zip"
      end
    end

    get "/" do
      @stories = story_rows
      @busy = settings.jobs.busy?
      @last_pull = library.repo.read_pull_log.last&.dig("timestamp")
      @flash = take_flash
      erb :index
    end

    post "/follow" do
      url = params[:url].to_s.strip
      name = params[:name].to_s.strip
      name = nil if name.empty?

      begin
        result = library.follow(url, name: name)
        if result[:followed]
          fic = result[:fic]
          settings.jobs.run do
            new_chapters = fic.pull
            app_logger.info("#{fic.display_title}: #{new_chapters.size} new chapter(s)")
            library.rebuild(fic)
          end
          # The title isn't fetched until the background pull runs, so fall back
          # to the user-supplied name (or a generic phrase) for the flash.
          flash! "Now following #{fic.display_title || "the story"}. Downloading and building…"
        else
          flash! "Already following that story."
        end
      rescue Library::InvalidURL => e
        flash! e.message
      end

      redirect to("/")
    end

    post "/pull" do
      started = settings.jobs.run { library.refresh(throttle: true) }
      flash!(started ? "Pull started." : "A pull is already running.")
      redirect to("/")
    end

    post "/rename" do
      fic_id = params[:fic_id].to_s
      halt 404, "Unknown story" unless followed?(fic_id)

      fic = library.rename(fic_id, params[:name])
      started = settings.jobs.run { library.rebuild(fic) }
      flash!(
        started ? "Renamed to #{fic.display_title}. Rebuilding…" :
          "Renamed to #{fic.display_title}. Rebuild will run once the current job finishes.",
      )
      redirect to("/")
    end

    post "/rebuild" do
      started = settings.jobs.run { library.rebuild_all }
      flash!(started ? "Rebuild started." : "A job is already running.")
      redirect to("/")
    end

    get "/download/:fic_id" do |fic_id|
      halt 404, "Unknown story" unless followed?(fic_id)
      fic = Fic.from_disk(fic_id, library.repo)
      send_epub(fic_id, "#{fic.display_title}.epub")
    end

    get "/download/:fic_id/volume/:volume_id" do |fic_id, volume_id|
      halt 404, "Unknown story" unless followed?(fic_id)
      fic = Fic.from_disk(fic_id, library.repo)
      vol = fic.volumes.find { |v| v["id"].to_s == volume_id }
      halt 404, "Unknown volume" unless vol
      send_epub(fic_id, "#{fic.display_title} - #{vol["title"]}.epub")
    end
  end
end
