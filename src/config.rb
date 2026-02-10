require 'json'
require 'fileutils'
require 'diffy'

# The Config is a simple JSON file that contains some basic settings and
# information. It's halfway between state file and configuration file, though it
# is intended to use CLI options to set options rather than edit this file
# directly.
class Config
  attr_accessor :last_run, :followed_stories
  attr_reader :verbose

  STATE_HOME = "#{Dir.home}/.config/peasant_road"

  def initialize(last_run: nil, followed_stories: nil)
    @last_run = last_run || Time.new
    @followed_stories = followed_stories || []
    @verbose = true

    Diffy::Diff.default_format = :color
  end

  def self.ensure_config_file
    return if File.exist?(STATE_HOME + "/config.json")
    FileUtils.mkdir_p(STATE_HOME)
    File.write(STATE_HOME + "/config.json", "{}")
  end

  def self.read_from_disk
    ensure_config_file

    state_content = File.read(STATE_HOME + "/config.json")
    config = JSON.parse(state_content, symbolize_names: true)
    new(**config)
  end

  def write_to_disk
    content = JSON.pretty_generate({
      last_run: @last_run,
      followed_stories: @followed_stories
    })
    File.write(STATE_HOME + "/config.json", content)
  end
end
