require "peasant_path"
require "peasant_path/royal_road_session"
require "playwright"

RSpec.describe PeasantPath::RoyalRoadSession do
  let(:challenge_html) { "<html><head><title>Making sure you&#39;re not a bot!</title></head><body></body></html>" }
  let(:fic_html) { "<html><head><title>Sky Pride | Royal Road</title></head><body>window.chapters = [];</body></html>" }

  describe ".challenge?" do
    it "recognises the Anubis interstitial" do
      expect(described_class.challenge?(challenge_html)).to be true
    end

    it "recognises the Cloudflare interstitial" do
      expect(described_class.challenge?("<title>Just a moment...</title>")).to be true
    end

    it "passes a regular page" do
      expect(described_class.challenge?(fic_html)).to be false
    end

    it "passes a chapter whose title merely contains the challenge's words" do
      expect(described_class.challenge?("<title>Just a Moment - Sky Pride | Royal Road</title>")).to be false
      expect(described_class.challenge?("<title>I am not a bot! - Sky Pride | Royal Road</title>")).to be false
    end

    it "passes a body with no title" do
      expect(described_class.challenge?("")).to be false
    end
  end

  describe ".pass_challenge" do
    it "waits until the page title is no longer the challenge" do
      page = double("page", goto: nil, wait_for_load_state: nil)
      allow(page).to receive(:title).and_return("Making sure you're not a bot!", "Sky Pride | Royal Road")
      allow(described_class).to receive(:sleep)

      described_class.pass_challenge(page, "https://www.royalroad.com/")

      expect(page).to have_received(:goto).with("https://www.royalroad.com/")
      expect(page).to have_received(:title).twice
      expect(page).to have_received(:wait_for_load_state)
    end

    it "does not take the empty title of a just-committed document as a pass" do
      page = double("page", goto: nil, wait_for_load_state: nil)
      allow(page).to receive(:title).and_return("", "Home | Royal Road")
      allow(described_class).to receive(:sleep)

      described_class.pass_challenge(page, "https://www.royalroad.com/")

      expect(page).to have_received(:title).twice
    end

    it "gives up with a ScrapeError once the timeout passes" do
      page = double("page", goto: nil, title: "Making sure you're not a bot!")
      allow(described_class).to receive(:sleep)

      expect {
        described_class.pass_challenge(page, "https://www.royalroad.com/", timeout: -1)
      }.to raise_error(PeasantPath::RoyalRoadClient::ScrapeError, /bot check.*not a bot/)
    end
  end

  describe PeasantPath::RoyalRoadSession::Transport do
    let(:page) { double("page") }
    let(:transport) { described_class.new(page) }

    it "returns the status and body of an in-page fetch" do
      allow(page).to receive(:evaluate).with(anything, arg: "/fiction/107917/").and_return("status" => 200, "body" => fic_html)

      expect(transport.get_text("/fiction/107917/")).to eq [200, fic_html]
    end

    it "solves a challenge that appears mid-session and retries the fetch once" do
      allow(page).to receive(:evaluate).and_return({ "status" => 200, "body" => challenge_html }, { "status" => 200, "body" => fic_html })
      allow(PeasantPath::RoyalRoadSession).to receive(:pass_challenge)

      expect(transport.get_text("/fiction/107917/")).to eq [200, fic_html]
      expect(PeasantPath::RoyalRoadSession).to have_received(:pass_challenge).with(page, "/fiction/107917/")
    end

    it "retries a fetch whose page navigated away underneath it" do
      destroyed = Playwright::Error.new(message: "Execution context was destroyed, most likely because of a navigation")
      calls = 0
      allow(page).to receive(:evaluate) do
        calls += 1
        raise destroyed if calls == 1
        { "status" => 200, "body" => fic_html }
      end
      allow(page).to receive(:wait_for_load_state)

      expect(transport.get_text("/fiction/107917/")).to eq [200, fic_html]
      expect(page).to have_received(:wait_for_load_state).with(state: "domcontentloaded")
    end

    it "gives up after a few destroyed contexts" do
      allow(page).to receive(:evaluate).and_raise(Playwright::Error.new(message: "Execution context was destroyed"))
      allow(page).to receive(:wait_for_load_state)

      expect { transport.get_text("/fiction/107917/") }.to raise_error(Playwright::Error)
      expect(page).to have_received(:evaluate).exactly(3).times
    end
  end

  # Needs a real Chromium and network access; excluded by default via .rspec.
  # Run with:
  #   bundle exec rspec spec/royal_road_session_spec.rb --tag browser
  describe ".open", :browser do
    it "gets past the bot check and fetches a fic page with its chapter list" do
      described_class.open do |transport|
        status, body = transport.get_text("/fiction/21220/")
        expect(status).to eq 200
        expect(body).to include("window.chapters =")
      end
    end
  end
end
