require_relative './royal_road_client'
require_relative './config'

require 'json'
require 'fileutils'

class Fic
  FIC_ID_REGEX = /https:\/\/www\.royalroad\.com\/fiction\/(\d+)\//

  attr_accessor :title, :uri, :author, :chapters, :description
  attr_reader :rr, :fic_id, :state_path, :config

  def initialize(uri:, config:)
    @config = config
    @uri = uri
    @fic_id = FIC_ID_REGEX.match(uri)[1]
    @state_path = "#{Config::STATE_HOME}/#{fic_id}"
    @chapters = nil
    @title = nil
    @author = nil
    @rr = RoyalRoadClient.new
  end

  def fetch_fic_info
    info = @rr.fic_info(@uri.to_s)
    @author = info[:author]
    @title = info[:title]
    @description = info[:description]
    self
  end

  def chapters
    @rr.chapters(@uri.to_s)
  end

  def persist
    diff = persist_fic_info(@fic_id, @author, @title, @description)
  end

  def self.persist_chapter(fic_id, chapter_id, chapter_title, chapter_text)
    # existing_chapter = file.read()
  end

  # The RR fic ID found in the URL is considered the canon identifier of a fic,
  # after that, title and author and description are all mutable. Returns a
  # string-diff of what's changed.
  def persist_fic_info(fic_id, author, title, description)
    existing_state = {author: "", title: "", description: ""}
    begin
      existing_state = File.read("#{@state_path}/fic_info.json")
    rescue Errno::ENOENT
      if @config.verbose
        puts "Fic information not found, starting from blank"
      end
    end

    new_state = {author: author, title: title, description: description}.to_json
    # TODO(sar): This is fine for now, but this diffs unprettied json and is not
    # fantastic. Also should be verbosity-gated.
    puts Diffy::Diff.new(existing_state, new_state)

    FileUtils.mkdir_p(state_path)
    File.write("#{state_path}/fic_info.json", new_state.to_json)
  end
end
