require "httparty"
require "nokogiri"

module PeasantPath
  class RoyalRoadClient
    include HTTParty
    base_uri "www.royalroad.com"

    # A hung connection must never block the pull thread forever: because Jobs
    # serializes work, one stuck socket would leave the web UI's buttons
    # disabled until restart. Cap open and read time so a slow request fails and
    # gets retried on the next pull instead of wedging the daemon.
    HTTP_TIMEOUT_SECONDS = 30
    open_timeout HTTP_TIMEOUT_SECONDS
    read_timeout HTTP_TIMEOUT_SECONDS

    attr_writer :throttle

    def initialize
      @throttle = false
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

    def enrich_overview_chapter!(overview_chapter)
      raise if overview_chapter.uri.nil?

      sleep(rand(5..15)) if @throttle
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
      return nil if elem.attribute("disabled")
      elem.attribute("href").value
    end

    def download_picture(url)
      resp = HTTParty.get(url, open_timeout: HTTP_TIMEOUT_SECONDS, read_timeout: HTTP_TIMEOUT_SECONDS)
      if resp.code != 200
        raise "cover_image: got unexpected response code from the CDN: #{resp.inspect}"
      end
      resp.body
    end
  end
end
