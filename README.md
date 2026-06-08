# Peasant Path - Because EPubs are nice.

This is a small incremental scraper for RoyalRoad fics. It follows stories and
persists any new chapters to disk. It then can also assemble EPUBs based on
these scraped chapters.

State lives under `~/.config/peasant_path` (followed stories, scraped chapters,
covers, built EPUBs, and a pull log). The CLI and the web interface share that
same directory, so anything you do in one shows up in the other.

## CLI

```sh
# Follow one or more stories
peasant_path add https://www.royalroad.com/fiction/107917/sky-pride
peasant_path add -n "My Name" https://www.royalroad.com/fiction/12345/...

# Pull new chapters for every followed story
peasant_path pull [--throttle]

# Pull new chapters AND rebuild the EPUBs of stories that changed
peasant_path refresh [--throttle]

# Show what's new over a recent window (default 48h)
peasant_path report [--hours N]

# Build EPUB(s) to the current directory (interactive fzf selector if no IDs)
peasant_path build [FIC_ID...]
```

`--throttle` adds a 5–15s random delay between chapter downloads to stay under
RoyalRoad's rate limiting; use it for unattended/bulk runs.

## Web interface

A Sinatra app over the same state. It serves an index of followed stories with
download links, a form to follow new stories, and a "pull now" button. Following
a story kicks off a background pull + build, so a download link appears shortly
after.

```sh
peasant_path serve [--port 4567] [--bind 127.0.0.1]
# or, from a checkout:
bundle exec rackup config.ru
```

### Automatic pulling

The server pulls and rebuilds changed stories on a schedule. There are two
mechanisms; the web process picks one automatically.

**systemd (Linux, preferred).** Installs `--user` units: a web service kept
alive by `Restart=always`, plus a timer that runs `refresh` periodically.

```sh
peasant_path install [--interval HOURS] [--port N] [--bind ADDR]
systemctl --user daemon-reload
systemctl --user enable --now peasant-path-web.service peasant-path-pull.timer
loginctl enable-linger "$USER"   # keep user units running without an active login
```

When the timer is active, the web process detects it and does **not** also
schedule pulls in-process.

**In-process fallback.** When systemd isn't driving the pull (e.g. macOS, or no
units installed), `serve` runs an in-process loop instead, on the same interval.
Override behaviour with `PEASANT_PATH_SCHEDULER` (`off` / `internal` /
`external`) and the cadence with `PEASANT_PATH_INTERVAL_HOURS` (default 6).

**macOS launchd.** `peasant_path schedule [--interval HOURS]` installs a launchd
job that runs `refresh` (pull + rebuild) on an interval. This schedules the pull
only; run `serve` separately if you also want the web UI.

## Development

```sh
bundle install
bundle exec rspec      # tests
bundle exec rufo .     # formatting
```
