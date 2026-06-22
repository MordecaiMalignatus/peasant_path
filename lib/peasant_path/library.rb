require "uri"
require "time"
require "logger"
require "json"

module PeasantPath
  # The Library is the shared domain entry point for following stories and
  # pulling new chapters. Both the CLI and the web interface drive it, so the
  # logic lives here rather than inside any one front-end.
  class Library
    class InvalidURL < StandardError; end

    DEFAULT_ROOT = "#{Dir.home}/.config/peasant_path".freeze

    attr_reader :repo

    # logger defaults to a silent one so the CLI's own output isn't duplicated;
    # the web/daemon injects a real logger to record pulls and rebuilds.
    def initialize(repo: DiskRepository.new(DEFAULT_ROOT), logger: Logger.new(File::NULL), client: RoyalRoadClient.new)
      @repo = repo
      @logger = logger
      @client = client
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
      fic_id = validate_story_url(url)
      cfg = config
      return { fic_id: fic_id, followed: false } if cfg.followed_stories.include?(fic_id)

      cfg.followed_stories << fic_id
      # Register the follow with no network: write a minimal record so the story
      # shows up immediately, and leave the metadata, covers and chapters to the
      # background pull the caller queues. Otherwise the "fast" follow action
      # would block the web request on several CDN cover downloads.
      fic = Fic.new(fic_id: fic_id, repository: @repo)
      fic.display_name = name
      fic.persist_fic_info
      @repo.write_config(cfg)

      { fic_id: fic_id, followed: true, fic: fic }
    end

    def unfollow(fic_id)
      cfg = config
      removed = cfg.followed_stories.delete(fic_id.to_s)
      @repo.write_config(cfg)
      @logger.info("unfollowed #{fic_id}") if removed
      !!removed
    end

    # Change a story's display name, editing the persisted fic_info in place so
    # the cover, chapters and volumes are preserved. A blank name clears the
    # override, reverting to the scraped title. The built EPUBs are named after
    # the title, so they're renamed in place too — that keeps downloads working
    # until the (not-guaranteed-immediate) rebuild overwrites them. Returns the
    # reloaded Fic.
    def rename(fic_id, name)
      info = @repo.read_fic_info(fic_id)
      old_title = info["display_name"] || info["title"]
      cleaned = name.to_s.strip
      info["display_name"] = cleaned.empty? ? nil : cleaned
      @repo.write_fic_info_hash(fic_id, info)

      fic = Fic.from_disk(fic_id, @repo)
      new_title = fic.display_title
      if new_title != old_title
        @repo.rename_build(fic_id, @repo.epub_filename(old_title), @repo.epub_filename(new_title))
        fic.volumes.each do |vol|
          @repo.rename_build(fic_id, @repo.epub_filename("#{old_title} - #{vol["title"]}"), @repo.epub_filename("#{new_title} - #{vol["title"]}"))
        end
      end

      @logger.info("renamed #{fic_id} to #{new_title}")
      fic
    end

    # Pull new chapters for every followed story, append a pull-log entry, and
    # return per-fic results:
    #   [{ fic: <Fic>, new_chapters: [<Chapter>...], error: nil_or_message }, ...]
    def pull_all(throttle: false)
      results = []
      log_entry = { timestamp: Time.now.iso8601, fics: [] }

      followed.each do |fic|
        begin
          new_chapters = pull_fic(fic, throttle: throttle)
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

    def pull_fic(fic, throttle: false)
      @client.throttle = throttle
      chapters = fic.chapters
      chapter_toc = @client.chapter_overview(fic.fic_id).map { |chapter_hash| Chapter.from_overview_hash(chapter_hash, @repo) }
      chapters_to_pull = chapter_toc.filter { |rr_chapter| !chapters.include?(rr_chapter) }

      fic.apply_fic_info(@client.fic_info(fic.uri.to_s))
      fic.persist_fic_info

      new_chapters = chapters_to_pull.map { |chapter| @client.enrich_overview_chapter!(chapter).persist }
      chapters.concat(new_chapters)
      fic.refresh_stats!
      new_chapters
    end

    # Rebuild the combined and per-volume EPUBs for a fic into the repo's build
    # directory. Assumes the fic's chapters are already on disk (no pull).
    def rebuild(fic)
      fic.refresh_stats!
      fic.book.build_all(@repo.build_dir(fic.fic_id))
      @logger.info("rebuilt #{fic.display_title}")
    end

    # Given pull_all results, rebuild only the fics that gained chapters.
    def rebuild_changed(results)
      results.each { |r| rebuild(r[:fic]) if r[:new_chapters].any? }
    end

    # Rebuild the EPUBs for every followed story from the chapters on disk,
    # without pulling. Used by the web "rebuild all" action.
    def rebuild_all
      followed.each { |fic| rebuild(fic) }
    end

    # Pull every followed story and rebuild the ones that changed. The single
    # entry point used by both the systemd refresh job and the in-process
    # fallback scheduler. Returns the pull_all results.
    def refresh(throttle: false)
      results = pull_all(throttle: throttle)
      rebuild_changed(results)
      new_count = results.sum { |r| r[:new_chapters].size }
      errors = results.count { |r| r[:error] }
      @logger.info("refresh finished: #{new_count} new chapter(s) across #{results.size} stories#{errors.positive? ? ", #{errors} error(s)" : ""}")
      results
    end

    def report(hours: 48)
      cutoff = Time.now - (hours * 3600)
      entries = @repo.read_pull_log.select { |entry| Time.parse(entry["timestamp"]) >= cutoff }
      fic_data = report_data_from_entries(entries)

      config.followed_stories.each do |fic_id|
        next if fic_data.key?(fic_id)
        fic_data[fic_id] = { title: Fic.from_disk(fic_id, @repo).display_title, runs: [] }
      end

      sorted = fic_data.sort_by { |_, data| [-data[:runs].sum { |run| run[:new_chapters].length }, data[:title]] }
      active, quiet = sorted.partition { |_, data| data[:runs].any? { |run| run[:new_chapters].any? || run[:error] } }
      { active: active, quiet: quiet }
    end

    def pull_status_by_fic
      status = {}
      @repo.read_pull_log.each do |entry|
        entry["fics"].each do |fic|
          status[fic["fic_id"]] = {
            timestamp: entry["timestamp"],
            error: fic["error"],
            new_chapter_count: fic["new_chapters"].size,
          }
        end
      end
      status
    end

    private

    def report_data_from_entries(entries)
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
      fic_data
    end

    # Validate that +url+ is a RoyalRoad story URL and return its fic ID.
    # Every "this isn't a story URL" case — a malformed string, a non-RoyalRoad
    # host, or a RoyalRoad URL without a /fiction/<id>/ path — raises InvalidURL
    # so front-ends have a single error type to rescue.
    def validate_story_url(url)
      begin
        uri = URI(url)
      rescue URI::InvalidURIError
        raise InvalidURL, "'#{url}' is not a valid URL"
      end

      unless uri.host == "www.royalroad.com"
        raise InvalidURL, "'#{url}' is not a RoyalRoad URL"
      end

      fic_id = Fic.uri_to_fic_id(uri.to_s)
      raise InvalidURL, "'#{url}' is not a RoyalRoad story URL" if fic_id.nil?

      fic_id
    end
  end
end
