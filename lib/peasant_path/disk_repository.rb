require "fileutils"
require "json"

module PeasantPath
  class DiskRepository
    attr_reader :root_path

    def initialize(path)
      @root_path = path
    end

    def ensure_config_file
      return if File.exist?(config_path)
      FileUtils.mkdir_p(@root_path)
      atomic_write(config_path, "{}")
    end

    # String keys, matching read_fic_info and read_pull_log: every JSON read in
    # this repo returns string keys, so consumers don't have to remember which
    # file symbolizes and which doesn't.
    def read_config_file
      ensure_config_file
      JSON.parse(File.read(config_path))
    end

    def write_config_file(content)
      atomic_write(config_path, content)
    end

    def write_config(config)
      write_config_file(config.to_json)
    end

    def read_chapter_from_path(path)
      # This is obtained from list_chapters with an absolute path, no need to rebuild it.
      JSON.parse(File.read(path))
    end

    # This is used to read with a slug from the state file.
    def read_chapter(fic_id, chapter_id)
      JSON.parse(File.read(File.join(fic_dir(fic_id), chapter_id)))
    end

    def write_chapter(fic_id, chapter_id, content)
      FileUtils.mkdir_p(fic_dir(fic_id))
      atomic_write(File.join(fic_dir(fic_id), chapter_id), content)
    end

    def write_chapter_hash(fic_id, chapter_id, hash)
      write_chapter(fic_id, chapter_id, JSON.pretty_generate(hash))
    end

    def chapter_exists?(fic_id, chapter_id)
      File.exist?(File.join(fic_dir(fic_id), chapter_id))
    end

    def list_chapters(fic_id)
      items = Dir.glob(File.join(fic_dir(fic_id), "*"))
      return [] if items.empty?
      items.reject { |f| non_chapter_files(fic_id).include?(f) }
    end

    def volume_cover_image_path(fic_id, volume_id)
      File.join(fic_dir(fic_id), "volume_#{volume_id}_cover.jpg")
    end

    def write_volume_cover_image(fic_id, volume_id, content)
      FileUtils.mkdir_p(fic_dir(fic_id))
      atomic_write(volume_cover_image_path(fic_id, volume_id), content)
    end

    def read_volume_cover_image(fic_id, volume_id)
      File.read(volume_cover_image_path(fic_id, volume_id))
    end

    def read_fic_info(fic_id)
      JSON.parse(File.read(File.join(fic_dir(fic_id), "fic_info.json")))
    end

    def write_fic_info(fic_id, content)
      FileUtils.mkdir_p(fic_dir(fic_id))
      atomic_write(File.join(fic_dir(fic_id), "fic_info.json"), content)
    end

    def write_fic_info_hash(fic_id, hash)
      write_fic_info(fic_id, JSON.pretty_generate(hash))
    end

    def cover_image_path(fic_id)
      File.join(fic_dir(fic_id), "cover_image.jpg")
    end

    def write_cover_image(fic_id, content)
      FileUtils.mkdir_p(fic_dir(fic_id))
      atomic_write(cover_image_path(fic_id), content)
    end

    def pull_log_path
      File.join(@root_path, "pull_log.jsonl")
    end

    def append_pull_log(entry)
      FileUtils.mkdir_p(@root_path)
      File.open(pull_log_path, "a") { |f| f.puts(JSON.generate(entry)) }
    end

    def read_pull_log
      return [] unless File.exist?(pull_log_path)
      File.readlines(pull_log_path, chomp: true).map { |line| JSON.parse(line) }
    end

    # Built EPUBs live under a top-level "builds/<fic_id>/" directory, kept
    # separate from the fic directory so they're never mistaken for chapters by
    # #list_chapters.
    def build_dir(fic_id)
      File.join(@root_path, "builds", fic_id)
    end

    def epub_path(fic_id, filename)
      File.join(build_dir(fic_id), filename)
    end

    def epub_filename(title)
      "#{sanitize_filename(title)}.epub"
    end

    def sanitize_filename(name)
      sanitized = name.to_s.gsub(/[\\\/\x00-\x1f\x7f]/, " ").strip
      sanitized = sanitized.gsub(/[[:space:]]+/, " ")
      sanitized.empty? ? "untitled" : sanitized
    end

    def list_builds(fic_id)
      Dir.glob(File.join(build_dir(fic_id), "*.epub")).sort
    end

    # Rename a built EPUB in place, e.g. after a title change. No-op if the
    # source isn't present, so callers needn't check first.
    def rename_build(fic_id, old_filename, new_filename)
      old = epub_path(fic_id, old_filename)
      return unless File.exist?(old)
      File.rename(old, epub_path(fic_id, new_filename))
    end

    def non_chapter_files(fic_id)
      [File.join(fic_dir(fic_id), "fic_info.json"), cover_image_path(fic_id)] +
        Dir.glob(File.join(fic_dir(fic_id), "volume_*_cover.jpg"))
    end

    private

    def config_path
      File.join(@root_path, "config.json")
    end

    def fic_dir(fic_id)
      File.join(@root_path, fic_id)
    end

    def atomic_write(path, content)
      tmp = "#{path}.tmp.#{$PROCESS_ID}"
      File.write(tmp, content)
      File.rename(tmp, path)
    ensure
      FileUtils.rm_f(tmp) if tmp && File.exist?(tmp)
    end
  end
end
