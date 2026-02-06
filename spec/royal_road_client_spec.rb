require 'rspec'
require 'nokogiri'

require_relative '../src/royal_road_client'

RSpec.describe RoyalRoadClient do
  it "should correctly extract nav-button links" do
    input = Nokogiri::XML.parse(<<~XML).css('.btn')[0]
    <a class="btn btn-primary col-xs-12" href="/fiction/107917/sky-pride/chapter/2113560/chapter-2--gourmet-in-the-garbage">
       Next <br class="visible-xs-block">Chapter <i class="far fa-chevron-double-right ml-3"></i>
    </a>
    XML
    expect(RoyalRoadClient.extract_button_link(input)).to eq "/fiction/107917/sky-pride/chapter/2113560/chapter-2--gourmet-in-the-garbage"
  end

  it "should return nil when the button is disabled" do
    input = Nokogiri::XML.parse(<<~XML).css('.btn')[0]
    <button class="btn btn-primary col-xs-12" disabled="disabled">
        <i class="far fa-chevron-double-left mr-3"></i> Previous <br class="visible-xs-block">Chapter
    </button>
    XML

    expect(RoyalRoadClient.extract_button_link(input)).to be_nil
  end

end
