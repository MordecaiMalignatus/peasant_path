# Everything Peasant Path reads is UTF-8: scraped pages, the chapters and
# metadata on disk, and the JSON the Playwright driver sends back. Ruby takes
# its default encoding from the locale, and a process started without one (a
# minimal server, a service manager with no LANG) gets US-ASCII. Decoding the
# first non-ASCII byte then raises, and when that happens on playwright-ruby-
# client's reader thread the pull waits for a reply forever.
Encoding.default_external = Encoding::UTF_8

require "peasant_path/version"
require "peasant_path/config"
require "peasant_path/disk_repository"
require "peasant_path/word_counter"
require "peasant_path/chapter"
require "peasant_path/sources"
require "peasant_path/royal_road_client"
require "peasant_path/royal_road_source"
require "peasant_path/patreon_rich_text"
require "peasant_path/patreon_client"
require "peasant_path/epub"
require "peasant_path/fic"
require "peasant_path/library"
require "peasant_path/jobs"
require "peasant_path/scheduler"
require "peasant_path/cli"
