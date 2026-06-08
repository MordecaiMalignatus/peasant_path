require "fileutils"
require "json"

module PeasantPath
  class DiskRepository
    attr_reader :root_path

    def initialize(path)
      @root_path = path
    end

    def ensure_config_file
      return if File.exist?("#{@root_path}/config.json")
      FileUtils.mkdir_p(@root_path)
      File.write("#{@root_path}/config.json", "{}")
    end

    def read_config_file
      ensure_config_file
      JSON.parse(File.read("#{@root_path}/config.json"), symbolize_names: true)
    end

    def write_config_file(content)
      File.write("#{@root_path}/config.json", content)
    end

    def read_chapter_from_path(path)
      # This is obtained from list_chapters with an absolute path, no need to rebuild it.
      JSON.parse(File.read(path))
    end

    # This is used to read with a slug from the state file.
    def read_chapter(fic_id, chapter_id)
      JSON.parse(File.read("#{fic_dir(fic_id)}/#{chapter_id}"))
    end

    def write_chapter(fic_id, chapter_id, content)
      FileUtils.mkdir_p(fic_dir(fic_id))
      File.write("#{fic_dir(fic_id)}/#{chapter_id}", content)
    end

    def list_chapters(fic_id)
      items = Dir.glob("#{fic_dir(fic_id)}/*")
      return [] if items.empty?
      items.reject { |f| non_chapter_files(fic_id).include?(f) }
    end

    def volume_cover_image_path(fic_id, volume_id)
      "#{fic_dir(fic_id)}/volume_#{volume_id}_cover.jpg"
    end

    def write_volume_cover_image(fic_id, volume_id, content)
      FileUtils.mkdir_p(fic_dir(fic_id))
      File.write(volume_cover_image_path(fic_id, volume_id), content)
    end

    def read_volume_cover_image(fic_id, volume_id)
      File.read(volume_cover_image_path(fic_id, volume_id))
    end

    def read_fic_info(fic_id)
      JSON.parse(File.read("#{fic_dir(fic_id)}/fic_info.json"))
    end

    def write_fic_info(fic_id, content)
      FileUtils.mkdir_p(fic_dir(fic_id))
      File.write("#{fic_dir(fic_id)}/fic_info.json", content)
    end

    def cover_image_path(fic_id)
      "#{fic_dir(fic_id)}/cover_image.jpg"
    end

    def write_cover_image(fic_id, content)
      FileUtils.mkdir_p(fic_dir(fic_id))
      File.write(cover_image_path(fic_id), content)
    end

    def pull_log_path
      "#{@root_path}/pull_log.jsonl"
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
      "#{@root_path}/builds/#{fic_id}"
    end

    def epub_path(fic_id, filename)
      "#{build_dir(fic_id)}/#{filename}"
    end

    def list_builds(fic_id)
      Dir.glob("#{build_dir(fic_id)}/*.epub").sort
    end

    # Rename a built EPUB in place, e.g. after a title change. No-op if the
    # source isn't present, so callers needn't check first.
    def rename_build(fic_id, old_filename, new_filename)
      old = epub_path(fic_id, old_filename)
      return unless File.exist?(old)
      File.rename(old, epub_path(fic_id, new_filename))
    end

    def non_chapter_files(fic_id)
      ["#{fic_dir(fic_id)}/fic_info.json", cover_image_path(fic_id)] + Dir.glob("#{fic_dir(fic_id)}/volume_*_cover.jpg")
    end

    private

    def fic_dir(fic_id)
      "#{@root_path}/#{fic_id}"
    end
  end
end
