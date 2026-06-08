require "json"

module PeasantPath
  # The Config is a simple JSON file that contains some basic settings and
  # information. It's halfway between state file and configuration file, though it
  # is intended to use CLI options to set options rather than edit this file
  # directly.
  class Config
    attr_accessor :followed_stories

    def initialize(followed_stories: nil)
      @followed_stories = followed_stories || []
    end

    # Read only the keys we know about. Config files outlive code, so an unknown
    # key (a setting added by a newer version, or a hand-edit) must be ignored
    # rather than crash every command with ArgumentError.
    def self.from_config_file(config_content)
      new(followed_stories: config_content[:followed_stories])
    end

    def to_json
      JSON.pretty_generate({
        followed_stories: @followed_stories,
      })
    end
  end
end
