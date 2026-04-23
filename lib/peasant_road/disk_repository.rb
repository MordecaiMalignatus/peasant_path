require "fileutils"
require "json"

module PeasantRoad
  class DiskRepository
    attr_reader :root_path

    def initialize(path)
      @root_path = path
    end

    def ensure_config_file
      return if File.exist?("#{@root_path}/config.json")
      FileUtils.mkdir_p("#{root_path}/config.json")
      File.write("#{root_path}/config.json", "{}")
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
      JSON.parse(File.read("#{@root_path}/#{fic_id}/#{chapter_id}"))
    end

    def write_chapter(fic_id, chapter_id, content)
      FileUtils.mkdir_p("#{@root_path}/#{fic_id}")
      File.write("#{@root_path}/#{fic_id}/#{chapter_id}", content)
    end

    def list_chapters(fic_id)
      items = Dir.glob("#{@root_path}/#{fic_id}/*")
      if items.empty?
        puts "No existing fic_info.json file found when discovering, starting from scratch..."
        []
      else
        items.reject { |f| non_chapter_files(fic_id).include?(f) }
      end
    end

    def volume_cover_image_path(fic_id, volume_id)
      "#{@root_path}/#{fic_id}/volume_#{volume_id}_cover.jpg"
    end

    def write_volume_cover_image(fic_id, volume_id, content)
      FileUtils.mkdir_p("#{@root_path}/#{fic_id}/")
      File.write(volume_cover_image_path(fic_id, volume_id), content)
    end

    def read_volume_cover_image(fic_id, volume_id)
      File.read(volume_cover_image_path(fic_id, volume_id))
    end

    def read_fic_info(fic_id)
      JSON.parse(File.read("#{@root_path}/#{fic_id}/fic_info.json"))
    end

    def write_fic_info(fic_id, content)
      FileUtils.mkdir_p("#{@root_path}/#{fic_id}/")
      File.write("#{@root_path}/#{fic_id}/fic_info.json", content)
    end

    def read_cover_image(fic_id)
      File.read("#{@root_path}/#{fic_id}/cover_image.jpg")
    end

    def cover_image_path(fic_id)
      "#{@root_path}/#{fic_id}/cover_image.jpg"
    end

    def write_cover_image(fic_id, content)
      FileUtils.mkdir_p("#{@root_path}/#{fic_id}/")
      File.write("#{@root_path}/#{fic_id}/cover_image.jpg", content)
    end

    def non_chapter_files(fic_id)
      base = "#{@root_path}/#{fic_id}"
      ["#{base}/fic_info.json", "#{base}/cover_image.jpg"] + Dir.glob("#{base}/volume_*_cover.jpg")
    end
  end
end
