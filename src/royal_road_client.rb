require 'httparty'
require 'nokogiri'

require_relative './chapter'

class RoyalRoadClient
  include HTTParty
  base_uri 'www.royalroad.com'

  def initialize(config)
    @options = {query: {} }
    @config = config
  end

  def fic_info(uri)
    toc = self.class.get(uri)
    doc = Nokogiri::HTML(toc.body)
    cover_image_url = doc.css('.fic-header').css('img').attribute('src').value

    {
      description: doc.css('.description').text.strip,
      title: doc.css('.fic-title').css('h1').text.strip,
      # TODO(sar): Capture author profile URL
      author: doc.css('.fic-title').css('a').text.strip,
      cover_image: download_picture(cover_image_url),
    }
  end

  # Pick out the chapter titles and their URLs.
  def chapter_overview(id)
    toc = self.class.get("/fiction/#{id}/")
    doc = Nokogiri::HTML(toc.body)
    links = doc.css('.chapter-row').map {|row| row.css('a')[0] }
    links.map {|link| [link.content().strip, link['href']]}.to_h
  end

  # Query a chapter with its full URI and return a Chapter.
  def fetch_chapter(uri)
    resp = self.class.get(uri)
    doc = Nokogiri::HTML(resp.body)
    nav_buttons = doc.css('.nav-buttons').css('.btn')

    res = Chapter.new(uri, @config)
    res.chapter_text = doc.css('.chapter-content').to_s # preserve the HTML here.
    res.chapter_title = doc.css('div.col-md-5.col-lg-6.col-md-offset-1 > h1').text.strip
    res.previous_chapter = RoyalRoadClient.extract_button_link(nav_buttons[0])
    res.next_chapter = RoyalRoadClient.extract_button_link(nav_buttons[1])

    res
  end

  def self.extract_button_link(elem)
    return nil if !elem.attribute("disabled").nil?
    elem.attribute("href").value
  end

  def download_picture(url)
    resp = HTTParty.get(url)
    if resp.code != 200
      raise "cover_image: got unexpected response code from the CDN: #{resp.inspect}"
    end
    resp.body
  end
end
