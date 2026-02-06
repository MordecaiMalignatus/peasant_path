require_relative './chapter'
require_relative './royal_road_client'

# Represents a singular chapter of a fic.
class Chapter
  attr_reader :fic_id, :chapter_id
  attr_accessor :chapter_title, :chapter_text, :authors_opening_note, :authors_closing_note, :next_chapter, :previous_chapter

  CHAPTER_REGEX = /https:\/\/www\.royalroad\.com\/fiction\/(\d+)\/[a-z-]+\/chapter\/(\d+)/

  def initialize(uri)
    match = CHAPTER_REGEX.match(uri)
    @fic_id = match[1]
    @chapter_id = match[2]
  end


  def persist

  end

end
