require_relative "./royal_road_client"
require_relative "./fic"
require_relative "./config"
require_relative "./disk_repository"

require "pry"
require "uri"
require "pp"

class Main
  attr_accessor :config
  attr_reader :rr, :repo

  def initialize
    @rr = RoyalRoadClient.new()
    @repo = DiskRepository.new("#{Dir.home}/.config/peasant_road")
    @config = Config.from_config_file(@repo.read_config_file)

    args = ARGV
    command = args[0]
    case command
    when "add" then cmd_add(args[1..])
    when "pull" then cmd_pull(args[1..])
    when "build" then cmd_build(args[1..])
    else
      puts "valid subcommands are: add, pull"
    end
  end

  # Add a new fic to the state. Accepts either a full URL. Additional parameters
  # after the first are treated as additional URLs. Raises if one of the URLs is
  # malformed.
  def cmd_add(params)
    params.each do |p|
      uri = URI(p)
      raise "Not an RR URL" if uri.host != "www.royalroad.com"
      fic_id = Fic.uri_to_fic_id(uri.to_s)

      unless @config.followed_stories.include?(fic_id)
        @config.followed_stories << fic_id
        fic = Fic.new(fic_id: fic_id, chapters: [], repository: @repo)
        fic.fetch_fic_info.persist_fic_info
        puts "Followed #{fic.title}"
      else
        puts "Aready followed this fic, skipping config edit."
      end
    end

    @config.write_to_disk
  end

  # For each followed fic, pull all the chapters, save the new ones, and
  # progress report.
  def cmd_pull(params)
    puts "Pulling all followed fics..."

    fics = @config.followed_stories.map { |fic| Fic.from_disk(fic, @repo) }
    fics.each do |f|
      puts "Pulling #{f.title}..."
      f.pull
    end
  end

  # Build an Epub for the specified fic_id
  def cmd_build(params)
    params.each do |fid|
      puts "Trying to build epub for fic ID #{fid}..."
      f = Fic.from_disk(fid, @repo)
      f.to_book.build("#{f.title}.epub")
    end
  end
end

Main.new
