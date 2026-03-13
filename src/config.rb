require "json"
require "diffy"

# The Config is a simple JSON file that contains some basic settings and
# information. It's halfway between state file and configuration file, though it
# is intended to use CLI options to set options rather than edit this file
# directly.
class Config
  attr_accessor :last_run, :followed_stories
  attr_reader :verbose

  def initialize(last_run: nil, followed_stories: nil)
    @last_run = last_run || Time.new
    @followed_stories = followed_stories || []
    @verbose = true

    Diffy::Diff.default_format = :color
  end

  def self.from_config_file(config_content)
    new(**config_content)
  end

  def to_json
    JSON.pretty_generate({
                           last_run: @last_run,
                           followed_stories: @followed_stories,
                         })
  end
end
