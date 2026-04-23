require "httparty"
require "nokogiri"

module PeasantRoad
  class RoyalRoadClient
    include HTTParty
    base_uri "www.royalroad.com"

    def initialize
      @options = { query: {} }
    end

    def fic_info(uri)
      toc = self.class.get(uri)
      doc = Nokogiri::HTML(toc.body)
      cover_image_url = doc.css(".fic-header").css("img").attribute("src").value
      volumes_json = toc.body
        .lines
        .find { |line| /window\.volumes =/.match line }
        .strip
        .delete_prefix("window.volumes = ")
        .delete_suffix(";")

      volumes = JSON.load(volumes_json)
      volume_covers = volumes.each_with_object({}) do |vol, h|
        h[vol["id"]] = download_picture(vol["cover"])
      end

      {
        description: doc.css(".description").text.strip,
        title: doc.css(".fic-title").css("h1").text.strip,
        # TODO(sar): Capture author profile URL
        author: doc.css(".fic-title").css("a").text.strip,
        cover_image: download_picture(cover_image_url),
        volumes: volumes,
        volume_covers: volume_covers,
      }
    end

    # Pick out the chapter titles and their URLs. Returns a list of hashes
    # nicked from the JS of the rendered HTML.
    def chapter_overview(id)
      toc = self.class.get("/fiction/#{id}/")
      # There's an embedded script tag that assigns the chapters loaded to the
      # `window.chapters` variable, to render the page without needing to make
      # another API request. The SPA takes this and builds the UI. Extracting
      # this via JS would require running a puppeteered browser, but luckily
      # there is exactly one assignment to state done statically, and we can nab
      # it via string manipulation :v
      extracted_json = toc.body
        .lines
        .find { |line| /window\.chapters =/.match line }
        .strip
        .delete_prefix("window.chapters = ")
        .delete_suffix(";")

      JSON.load(extracted_json)
    end

    # Query a chapter with its full URI and return a Chapter.
    def fetch_chapter(uri, repo)
      resp = self.class.get(uri)
      doc = Nokogiri::HTML(resp.body)
      nav_buttons = doc.css(".nav-buttons").css(".btn")

      res = Chapter.new(uri, repo)
      res.chapter_text = doc.css(".chapter-content").to_s
      res.chapter_title = doc.css("div.col-md-5.col-lg-6.col-md-offset-1 > h1").text.strip
      res.previous_chapter = RoyalRoadClient.extract_button_link(nav_buttons[0])
      res.next_chapter = RoyalRoadClient.extract_button_link(nav_buttons[1])

      res
    end

    def enrich_overview_chapter!(overview_chapter)
      raise if overview_chapter.uri.nil?

      resp = self.class.get(overview_chapter.uri)
      doc = Nokogiri::HTML(resp.body)
      nav_buttons = doc.css(".nav-buttons").css(".btn")

      overview_chapter.chapter_text = doc.css(".chapter-content").to_s
      overview_chapter.chapter_title = doc.css("div.col-md-5.col-lg-6.col-md-offset-1 > h1").text.strip
      overview_chapter.previous_chapter = RoyalRoadClient.extract_button_link(nav_buttons[0])
      overview_chapter.next_chapter = RoyalRoadClient.extract_button_link(nav_buttons[1])

      overview_chapter
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
end
