require 'fileutils'
require 'json'
require_relative './config'

class DiskRepository
  attr_reader :root_path

  def initialize(path)
    @root_path = path
  end

  def ensure_config_file()
    return if File.exist?("#{@root_path}/config.json")
    FileUtils.mkdir_p("#{root_path}/config.json")
    File.write("#{root_path}/config.json", "{}")
  end

  def read_config_file()
    ensure_config_file
    JSON.parse(File.read("#{@root_path}/config.json"), symbolize_names: true)
  end

  def write_config_file(content)
    File.write("#{@root_path}/config.json", content)
  end

  def read_chapter(fic_id, chapter_id)
    JSON.parse(File.read("#{@root_path}/#{fic_id}/#{chapter_id}"))
  end

  def write_chapter(fic_id, chapter_id, content)
    FileUtils.mkdir_p(state_path)
    File.write("#{@root_path}/#{fic_id}/#{content}", content)
  end

  def list_chapters(fic_id)
    items = Dir.glob("#{@state_path}/*")
    if items.empty?
      puts "No existing fic_info.json file found when discovering, starting from scratch..."
      []
    else
      items - ["#{@root_path}/#{fic_id}/fic_info.json", "#{@root_path}/#{fic_id}/cover_image.jpg"]
    end
  end

  def read_fic_info(fic_id)
    JSON.parse(File.read("#{@root_path}/#{fic_id}/fic_info.json"))
  end

  def write_fic_info(fic_id, content)
    FileUtils.mkdir_p(state_path)
    File.write("#{@root_path}/#{fic_id}/fic_info.json", content)
  end

  def read_cover_image(fic_id)
    File.read("#{@root_path}/#{fic_id}/cover_image.jpg")
  end

  def write_cover_image(fic_id, content)
    FileUtils.mkdir_p(state_path)
    File.write("#{@root_path}/#{fic_id}/cover_image.jpg", content)
  end
end
