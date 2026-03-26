require "peasant_road"

RSpec.describe PeasantRoad::Epub do
  let(:sky_pride_html) { File.read(File.expand_path("../data/sky-pride.html", __dir__)) }
  let(:chapter_1_html) { File.read(File.expand_path("../data/chapter-1.html", __dir__)) }

  describe ".correct_html_to_xhtml" do
    it "should close all <p> tags" do
      expect(PeasantRoad::Epub.correct_html_to_xhtml(chapter_1_html)).to not_include "<p>"
    end

    it "should close all <br> tags" do
      expect(PeasantRoad::Epub.correct_html_to_xhtml(chapter_1_html)).to not_include "<br>"
    end
  end
end
