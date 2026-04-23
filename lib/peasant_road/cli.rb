require "uri"
require "thor"

module PeasantRoad
  class CLI < Thor
    def self.exit_on_failure?
      true
    end

    def initialize(*args)
      super
      @rr = RoyalRoadClient.new
      @repo = DiskRepository.new("#{Dir.home}/.config/peasant_road")
      @config = Config.from_config_file(@repo.read_config_file)
    end

    desc "add URL [URL...]", "Follow one or more RoyalRoad stories by URL"
    option :name, type: :string, aliases: "-n", desc: "Override display name for the story"

    def add(*urls)
      if urls.empty?
        raise Thor::Error, "Please provide at least one RoyalRoad URL"
      end

      urls.each do |url|
        uri = URI(url)
        unless uri.host == "www.royalroad.com"
          raise Thor::Error, "'#{url}' is not a RoyalRoad URL"
        end

        fic_id = Fic.uri_to_fic_id(uri.to_s)

        unless @config.followed_stories.include?(fic_id)
          @config.followed_stories << fic_id
          fic = Fic.new(fic_id: fic_id, repository: @repo)
          fic.display_name = options[:name]
          fic.fetch_fic_info.persist_fic_info
          puts "Followed #{fic.display_title}"
        else
          puts "Already following this fic, skipping."
        end
      end

      @repo.write_config_file(@config.to_json)
    end

    desc "pull", "Pull new chapters for all followed stories"

    def pull
      puts "Pulling all followed fics..."

      fics = @config.followed_stories.map { |fic| Fic.from_disk(fic, @repo) }
      fics.each do |f|
        puts "Pulling #{f.display_title}..."
        f.pull
      end
    end

    desc "backfill_volumes", "One-time migration: backfill volume and order data for existing chapters"

    def backfill_volumes
      fics = @config.followed_stories.map { |fic_id| Fic.from_disk(fic_id, @repo) }
      fics.each do |f|
        puts "Backfilling volumes for #{f.display_title}..."
        f.backfill_chapter_volumes!
      end
      puts "Done."
    end

    desc "build FIC_ID [FIC_ID...]", "Build an EPUB for one or more followed stories"

    def build(*fic_ids)
      if fic_ids.empty?
        raise Thor::Error, "Please provide at least one fic ID"
      end

      fic_ids.each do |fid|
        puts "Building EPUB for fic ID #{fid}..."
        f = Fic.from_disk(fid, @repo)
        f.to_book.build("#{f.display_title}.epub")
      end
    end
  end
end
