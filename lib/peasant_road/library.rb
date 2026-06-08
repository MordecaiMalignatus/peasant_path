require "uri"
require "time"
require "logger"

module PeasantRoad
  # The Library is the shared domain entry point for following stories and
  # pulling new chapters. Both the CLI and the web interface drive it, so the
  # logic lives here rather than inside any one front-end.
  class Library
    class InvalidURL < StandardError; end

    DEFAULT_ROOT = "#{Dir.home}/.config/peasant_road".freeze

    attr_reader :repo

    # logger defaults to a silent one so the CLI's own output isn't duplicated;
    # the web/daemon injects a real logger to record pulls and rebuilds.
    def initialize(repo: DiskRepository.new(DEFAULT_ROOT), logger: Logger.new(File::NULL))
      @repo = repo
      @logger = logger
    end

    def config
      Config.from_config_file(@repo.read_config_file)
    end

    def followed
      config.followed_stories.map { |fic_id| Fic.from_disk(fic_id, @repo) }
    end

    # Follow a RoyalRoad story by URL. Idempotent: following an already-followed
    # story is a no-op. Returns a result hash:
    #   { fic_id:, followed: true,  fic: <Fic> }  when newly followed
    #   { fic_id:, followed: false }              when already followed
    def follow(url, name: nil)
      uri = URI(url)
      unless uri.host == "www.royalroad.com"
        raise InvalidURL, "'#{url}' is not a RoyalRoad URL"
      end

      fic_id = Fic.uri_to_fic_id(uri.to_s)
      cfg = config
      return { fic_id: fic_id, followed: false } if cfg.followed_stories.include?(fic_id)

      cfg.followed_stories << fic_id
      fic = Fic.new(fic_id: fic_id, repository: @repo)
      fic.display_name = name
      fic.fetch_fic_info.persist_fic_info
      @repo.write_config_file(cfg.to_json)

      { fic_id: fic_id, followed: true, fic: fic }
    end

    # Pull new chapters for every followed story, append a pull-log entry, and
    # return per-fic results:
    #   [{ fic: <Fic>, new_chapters: [<Chapter>...], error: nil_or_message }, ...]
    def pull_all(throttle: false)
      results = []
      log_entry = { timestamp: Time.now.iso8601, fics: [] }

      followed.each do |fic|
        begin
          new_chapters = fic.pull(throttle: throttle)
          results << { fic: fic, new_chapters: new_chapters, error: nil }
          @logger.info("#{fic.display_title}: #{new_chapters.size} new chapter(s)") if new_chapters.any?
          log_entry[:fics] << {
            fic_id: fic.fic_id,
            title: fic.display_title,
            new_chapters: new_chapters.map(&:chapter_title),
          }
        rescue => e
          @logger.warn("#{fic.display_title}: pull failed: #{e.message}")
          results << { fic: fic, new_chapters: [], error: e.message }
          log_entry[:fics] << {
            fic_id: fic.fic_id,
            title: fic.display_title,
            new_chapters: [],
            error: e.message,
          }
        end
      end

      @repo.append_pull_log(log_entry)
      results
    end

    # Rebuild the combined and per-volume EPUBs for a fic into the repo's build
    # directory. Assumes the fic's chapters are already on disk (no pull).
    def rebuild(fic)
      fic.book.build_all(@repo.build_dir(fic.fic_id))
      @logger.info("rebuilt #{fic.display_title}")
    end

    # Given pull_all results, rebuild only the fics that gained chapters.
    def rebuild_changed(results)
      results.each { |r| rebuild(r[:fic]) if r[:new_chapters].any? }
    end

    # Pull every followed story and rebuild the ones that changed. The single
    # entry point used by both the systemd refresh job and the in-process
    # fallback scheduler. Returns the pull_all results.
    def refresh(throttle: false)
      results = pull_all(throttle: throttle)
      rebuild_changed(results)
      results
    end
  end
end
