require 'httparty'
require 'nokogiri'

class RoyalRoadClient
  include HTTParty
  base_uri 'www.royalroad.com'

  def initialize()
    @options = {query: {} }
  end

  def fic_info(uri)
    toc = self.class.get(uri)
    doc = Nokogiri::HTML(toc.body)
    {
      description: doc.css('.description').text.strip,
      title: doc.css('.fic-title').css('h1').text.strip,
      # TODO(sar): Capture author profile URL
      author: doc.css('.fic-title').css('a').text.strip,
    }
  end

  # Pick out the chapter titles and their URLs.
  def chapters(id)
    toc = self.class.get("/fiction/#{id}/")
    doc = Nokogiri::HTML(toc.body)
    links = doc.css('.chapter-row').map {|row| row.css('a')[0] }
    links.map {|link| [link.content().strip, link['href']]}.to_h
  end

  # Query a chapter with its full URI and return the body HTML as a NodeSet.
  def chapter(uri)
    resp = self.class.get(uri)
    doc = Nokogiri::HTML(resp.body)
    doc.css '.chapter-content'
  end
end
