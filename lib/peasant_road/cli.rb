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
        puts "  Pulling #{f.display_title}..."
        f.pull
      end
    end

    desc "build [FIC_ID...]", "Build an EPUB for one or more followed stories (interactive selector if no IDs given)"

    def build(*fic_ids)
      if fic_ids.empty?
        fic_ids = select_fics_with_fzf
        return if fic_ids.empty?
      end

      fic_ids.each do |fid|
        puts "Building EPUB for fic ID #{fid}..."
        f = Fic.from_disk(fid, @repo)
        f.to_book.build_all("#{f.display_title}.epub")
      end
    end

    private

    def select_fics_with_fzf
      fics = @config.followed_stories.map { |fic_id| Fic.from_disk(fic_id, @repo) }
      input = fics.map { |f| "#{f.display_title}\t#{f.fic_id}" }.join("\n")

      output = IO.popen(["fzf", "--multi", "--with-nth=1", "--delimiter=\t"], "r+") do |io|
        io.write(input)
        io.close_write
        io.read
      end

      return [] if output.nil? || output.strip.empty?
      output.strip.split("\n").map { |line| line.split("\t", 2).last }
    rescue Errno::ENOENT
      raise Thor::Error, "fzf not found. Install fzf or provide fic IDs directly."
    end
  end
end
