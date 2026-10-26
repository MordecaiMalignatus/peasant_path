# Peasant Path - Because EPubs are nice.

This is a small incremental scraper for RoyalRoad fics and Patreon
collections or creator feeds. It follows stories and
persists any new chapters to disk. It then can also assemble EPUBs based on
these scraped chapters.

State lives under `~/.config/peasant_path` (followed stories, scraped chapters,
covers, built EPUBs, and a pull log). The CLI and the web interface share that
same directory, so anything you do in one shows up in the other.

## Browser

Neither site answers a plain HTTP client: RoyalRoad sits behind an Anubis
proof-of-work check and Patreon behind Cloudflare's browser fingerprinting.
Every pull therefore runs in a headless Chromium driven by Playwright, which
needs Node:

```sh
peasant_path browser install      # one-off: npm-installs the driver and Chromium under ~/.config/peasant_path
```

`browser install` needs `npm` on the PATH and puts everything under
`~/.config/peasant_path/patreon/driver/`, so it works for an installed gem as
well as a checkout. (From a checkout, `bin/install_system_dependencies` does
the same into `./node_modules`, which the driver lookup also checks.) On Linux,
Chromium additionally needs system libraries: `sudo <driver>/node_modules/.bin/playwright-core install-deps chromium`.
`PEASANT_PATH_PLAYWRIGHT_CLI` overrides the lookup with an explicit
`playwright-core` path. The container image ships with both already installed.

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

From a checkout, the web UI can also run in a Podman container while using the
same local state directory as the non-container app:

```sh
bin/run_container --build
```

This mounts `~/.config/peasant_path` into the container, so followed stories,
chapters, covers, pull logs, and built EPUBs are shared with local CLI runs.

> **Exposure caveat.** The app has no authentication and no Host-header check,
> and it mutates state (triggers scrapes, writes files). That's fine bound to
> the default `127.0.0.1`. If you `--bind` to a non-loopback address you're
> putting an unauthenticated, mutating, DNS-rebinding-susceptible app on the
> network — only do so behind a trusted reverse proxy / your own auth.
>
> **Session secret.** Flash messages use a signed session cookie. With no
> `PEASANT_PATH_SESSION_SECRET` set, each process generates a random one at
> boot, which is fine for a single worker but breaks flashes across a
> multi-worker Puma and invalidates sessions on restart. Set
> `PEASANT_PATH_SESSION_SECRET` to a fixed value if you run more than one worker.

### Automatic pulling

The server pulls and rebuilds changed stories on a schedule. A single `install`
command detects the host OS and sets up the right scheduler, always falling back
to in-process scheduling when no external one is available.

```sh
peasant_path install [--interval HOURS] [--port N] [--bind ADDR]
```

**systemd (Linux, preferred).** Installs `--user` units: a web service kept
alive by `Restart=always`, plus a timer that runs `refresh` periodically.

```sh
systemctl --user daemon-reload
systemctl --user enable --now peasant-path-web.service peasant-path-pull.timer
loginctl enable-linger "$USER"   # keep user units running without an active login
```

When the timer is active, the web process detects it and does **not** also
schedule pulls in-process.

**launchd (macOS).** Installs a launchd job that runs `refresh` (pull + rebuild)
on an interval, then prints the `launchctl load` command. This schedules the
pull only; run `serve` separately if you also want the web UI. `--port`/`--bind`
apply to the systemd web service and are ignored here.

**In-process fallback.** When no external scheduler is installed (or the host
supports neither systemd nor launchd), `serve` runs an in-process loop on the
same interval. Override behaviour with `PEASANT_PATH_SCHEDULER` (`off` /
`internal` / `external`) and the cadence with `PEASANT_PATH_INTERVAL_HOURS`
(default 6).

## Patreon

Patreon collections and creator feeds can be followed too. On top of the
[browser](#browser), they need a logged-in Patreon session:

```sh
peasant_path patreon login        # opens a browser window; sign in once
peasant_path patreon status       # who the saved session belongs to
peasant_path patreon logout       # forget the saved browser profile
```

### Moving the login to another machine

The login lives in a browser profile under `~/.config/peasant_path/patreon/`.
Three ways to get a logged-in session onto a fresh machine:

1. **It has a display:** run `peasant_path patreon login` there.
2. **It is headless (a server, a container host):** on a machine where you
   are logged in, run `peasant_path patreon export` to write
   `patreon-session.json`, copy that file over, then run
   `peasant_path patreon import patreon-session.json` on the target. The file
   holds your session cookie, so treat it like a password and delete it
   after importing.
3. **Cloning the whole state:** copying `~/.config/peasant_path` carries the
   profile along; Playwright's Chromium stores its cookies without tying them
   to the machine's keychain, so the login survives the move.

A Patreon session lasts about a year; `patreon status` tells you when it has
expired, and a failed pull says so in the pull log.

The login is kept in a browser profile under `~/.config/peasant_path/patreon/`
and reused headlessly by every pull. The container has no display to log in
from, so a login there has to come through `patreon import`.

## Development

```sh
bin/install_system_dependencies
bundle install
bundle exec rspec      # tests
bundle exec rufo .     # formatting
```

`ffi-icu` provides Unicode word-boundary analysis for EPUB word-count estimates.
On Ubuntu this requires `libicu-dev`; on macOS the install script uses Homebrew's
`icu4c@78` formula and prints the environment variables needed for the current
shell.
