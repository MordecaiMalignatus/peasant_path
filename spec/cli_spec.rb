require "peasant_path"
require "peasant_path/patreon_session"
require "tmpdir"

RSpec.describe PeasantPath::CLI, "patreon subcommands" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:session) { double("PatreonSession") }

  # CLI#initialize opens the real state directory; point it at a scratch one
  # so running the command never touches ~/.config, and swap the session
  # module for a double so no browser is launched.
  before do
    allow(PeasantPath::DiskRepository).to receive(:new).and_return(PeasantPath::DiskRepository.new(tmpdir))
    allow(PeasantPath::CLI).to receive(:patreon_session).and_return(session)
  end

  after { FileUtils.rm_rf(tmpdir) }

  it "reports the logged-in user" do
    allow(session).to receive(:status).with(profile_dir: PeasantPath::Library::PATREON_PROFILE_DIR).and_return("Reader")

    expect { described_class.start(%w[patreon status]) }.to output(/Logged in as Reader\./).to_stdout
  end

  it "says when nobody is logged in" do
    allow(session).to receive(:status).and_return(nil)

    expect { described_class.start(%w[patreon status]) }.to output(/Not logged in\. Run 'peasant_path patreon login'/).to_stdout
  end

  it "turns a missing browser driver into a Thor error" do
    allow(session).to receive(:status).and_raise(PeasantPath::PatreonSession::NotInstalled, "playwright-core not found. Install it")

    expect { described_class.start(%w[patreon status]) }.to raise_error(SystemExit).and output(/playwright-core not found/).to_stderr
  end

  it "runs the interactive login and confirms the account" do
    allow(session).to receive(:login).with(profile_dir: PeasantPath::Library::PATREON_PROFILE_DIR, io: anything).and_return("Reader")

    expect { described_class.start(%w[patreon login]) }.to output(/Logged in as Reader\. Patreon pulls will use this session\./).to_stdout
  end

  it "reports an aborted login as a Thor error" do
    allow(session).to receive(:login).and_raise(PeasantPath::PatreonSession::LoginAborted, "the browser window was closed before logging in")

    expect { described_class.start(%w[patreon login]) }.to raise_error(SystemExit).and output(/browser window was closed/).to_stderr
  end

  it "removes the saved session on logout" do
    allow(session).to receive(:logout).with(profile_dir: PeasantPath::Library::PATREON_PROFILE_DIR).and_return(true)

    expect { described_class.start(%w[patreon logout]) }.to output(/Patreon session removed\./).to_stdout
  end

  it "says so when there was no session to remove" do
    allow(session).to receive(:logout).and_return(false)

    expect { described_class.start(%w[patreon logout]) }.to output(/No Patreon session saved\./).to_stdout
  end

  it "exports the session to a file and says how to import it" do
    allow(session).to receive(:export).with(profile_dir: PeasantPath::Library::PATREON_PROFILE_DIR, path: "patreon-session.json").and_return(7)

    expect { described_class.start(%w[patreon export]) }.to output(/Wrote 7 cookie\(s\) to patreon-session\.json.*patreon import patreon-session\.json/).to_stdout
  end

  it "refuses to export a profile that is not logged in" do
    allow(session).to receive(:export).and_raise(PeasantPath::PatreonClient::AuthRequired, "the saved profile is not logged in")

    expect { described_class.start(%w[patreon export out.json]) }.to raise_error(SystemExit).and output(/not logged in/).to_stderr
  end

  it "imports a session file and confirms the account" do
    allow(session).to receive(:import).with(profile_dir: PeasantPath::Library::PATREON_PROFILE_DIR, path: "s.json").and_return("Reader")

    expect { described_class.start(%w[patreon import s.json]) }.to output(/Logged in as Reader\./).to_stdout
  end

  it "reports an unreadable session file as a Thor error" do
    allow(session).to receive(:import).and_raise(Errno::ENOENT, "s.json")

    expect { described_class.start(%w[patreon import s.json]) }.to raise_error(SystemExit).and output(/could not read s\.json/).to_stderr
  end

  it "installs the driver from the patreon namespace too, pointing at login next" do
    browser = double("Browser")
    allow(PeasantPath::CLI).to receive(:browser).and_return(browser)
    allow(browser).to receive(:install).with(io: anything).and_return("/state/driver/node_modules/.bin/playwright-core")

    expect { described_class.start(%w[patreon install]) }.to output(%r{Installed /state/driver/node_modules/.bin/playwright-core\. Next: 'peasant_path patreon login'}).to_stdout
  end

  it "reports a missing npm from the patreon namespace as a Thor error" do
    browser = double("Browser")
    allow(PeasantPath::CLI).to receive(:browser).and_return(browser)
    allow(browser).to receive(:install).and_raise(PeasantPath::Browser::NotInstalled, "npm not found on PATH")

    expect { described_class.start(%w[patreon install]) }.to raise_error(SystemExit).and output(/npm not found/).to_stderr
  end
end

RSpec.describe PeasantPath::CLI, "browser subcommands" do
  let(:tmpdir) { Dir.mktmpdir }
  let(:browser) { double("Browser") }

  before do
    allow(PeasantPath::DiskRepository).to receive(:new).and_return(PeasantPath::DiskRepository.new(tmpdir))
    allow(PeasantPath::CLI).to receive(:browser).and_return(browser)
  end

  after { FileUtils.rm_rf(tmpdir) }

  it "installs the driver" do
    allow(browser).to receive(:install).with(io: anything).and_return("/state/driver/node_modules/.bin/playwright-core")

    expect { described_class.start(%w[browser install]) }.to output(%r{Installed /state/driver/node_modules/.bin/playwright-core\.}).to_stdout
  end

  it "reports a missing npm as a Thor error" do
    allow(browser).to receive(:install).and_raise(PeasantPath::Browser::NotInstalled, "npm not found on PATH")

    expect { described_class.start(%w[browser install]) }.to raise_error(SystemExit).and output(/npm not found/).to_stderr
  end
end
