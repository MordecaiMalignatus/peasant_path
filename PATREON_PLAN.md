# Plan: Patreon as a fic source

Status: implemented 2026-10-12 (Phases 0 to 4 plus the README part of
Phase 5), uncommitted on `main`. End-to-end verified against the target
collection: 563 chapters pulled headlessly in about a minute, one combined
EPUB built, second pull incremental (one API page, no new chapters). API
shapes below were verified live in a logged-in Playwright browser.

## Goal

Follow a Patreon **collection** (chapters = the posts in that collection) or
a Patreon **creator** (chapters = all of that creator's posts) the same way
we follow a Royal Road fic: `add URL`, `pull`, `refresh`, `build` and the
web UI keep working, and the EPUB looks like an RR one.

Authentication: a human logs into Patreon once in a Playwright-driven
browser; the saved browser profile is reused for unattended pulls.

## Concrete target

`https://www.patreon.com/collection/1522125?view=expanded`

| Field | Value |
|---|---|
| Collection title | Path of the Deathless |
| Collection id | 1522125 |
| Creator | OstensibleMammal, campaign id 9755002, vanity `u84402213` |
| Published posts | 563 (API `num_posts`); `post_ids` lists 585 because it includes 22 drafts |
| Post type | all `text_only` |
| Collection ordering | `post_sort_type: custom`; `post_ids` and `sort=collection_order` are newest first |
| Title pattern | `1  Pathless` … then `III-4  Responders`, `IX-34 New Exit`: roman-numeral arc prefix from arc II on |
| Stubbed chapters | some early chapters are replaced by `[Removed per stubbing for Kindle Unlimited Release]` |
| Body size | ~30 to 60 KB of ProseMirror JSON per chapter |

Pull cost for the first run: 563 posts at 20 per page, 29 API pages,
roughly 20 MB. Incremental pulls normally touch one page.

## Findings that shape the design

1. **Patreon's internal JSON:API is enough; no page scraping for text.**
   All requests take `json-api-version=1.0` and are made with
   `credentials: "include"` from a page on `www.patreon.com`.
   - `GET /api/collection/<id>` -> `attributes.title`, `thumbnail.url`
     (cover, signed URL), `num_posts`, `post_ids` (full order, newest
     first, drafts included), `post_sort_type`. No `relationships.campaign`;
     the campaign id is parsed from the thumbnail URL `/campaign/<id>/`.
   - `GET /api/campaigns/<id>?fields[campaign]=name,vanity,url,avatar_photo_url,summary&include=creator&fields[user]=full_name,vanity`
     -> author name, creator vanity, description, avatar as cover.
   - `GET /api/posts?filter[campaign_id]=<c>&filter[collection_id]=<col>&filter[contains_exclusive_posts]=true&filter[is_draft]=false&sort=collection_order`
     -> 20 posts per page, `links.next` carries `page[cursor]`,
     `meta.pagination.total`. Drop `filter[collection_id]` and use
     `sort=-published_at` for a creator feed. `sort=published_at` ascending
     also works and gave `1 Pathless, 2 Return, 3 Festival`. Do **not**
     restrict `fields[post]`: the default field set already includes
     everything we need and a restricted set drops `content_json_string`.
   - `GET /api/posts/<id>` works for a single post, same attributes.
   - `GET /api/current_user` -> 200 when logged in, 401 otherwise. This is
     the login check.
2. **The body is not HTML any more.** `attributes.content` is `null` for
   every post, logged in or not. The body lives in
   `attributes.content_json_string`, a ProseMirror document. Across eight
   sampled chapters the schema is: nodes `doc`, `paragraph`, `text`,
   `hardBreak`; marks `bold`, `italic`; one attribute
   `paragraph.attrs.nodeTextAlignment` (`center` on epigraphs). A converter
   is about forty lines. Non-text nodes (images, embeds, files, video,
   audio) become a minimal text placeholder; a post whose converted body
   has no text at all is dropped (decided 2026-10-12).
   Fallback if the JSON ever disappears: the rendered post page keeps the
   body in `div.patreon-post-content` as plain `<p>` elements.
3. **Locked posts** come back with `current_user_can_view: false` and an
   empty body. Logged in with the right tier, every post in the collection
   had `current_user_can_view: true`.
4. **Cloudflare blocks non-browser HTTP clients** on patreon.com by TLS
   fingerprint, even with a valid `session_id` cookie and browser
   User-Agent (gallery-dl issue #9371, April to August 2026). So **do not
   export cookies into HTTParty.** Every Patreon request, including the
   cover download, runs *inside* the Playwright page via `page.evaluate`
   calling `fetch`. Playwright's `APIRequestContext` is not enough either:
   it uses Node's TLS stack, not Chromium's.
5. **Creator pages are Next.js RSC streams**, no `window.patreon`
   bootstrap. The campaign id appears as backslash-escaped JSON:
   `\"pageBootstrap\":{\"campaign\":{\"data\":{\"id\":\"9755002\"`. The
   regex must allow an optional `\` before every quote. Only needed for
   creator URLs; collection URLs never touch HTML.
6. **playwright-ruby-client 1.64.0** (released 2026-10-12) needs Node and a
   matching `playwright-core@1.64.0` plus a Chromium download. It supports
   `launch_persistent_context`, headful mode and `page.evaluate`. It must
   be an optional, lazily required dependency so RR-only users never need
   Node.
7. The current code is RR-shaped end to end: `Fic#uri`, `Fic::FIC_ID_REGEX`,
   `Chapter#initialize` (parses ids out of an RR URL),
   `Library#validate_story_url`, `Library#pull_fic` (calls RR client
   methods directly), `Epub` (RR identifier, `rr-ch-` anchors). A small
   source abstraction has to land first.

## Design

### Identifiers and on-disk layout

`fic_id` is the directory name under `~/.config/peasant_path/` and
`builds/`, so it must be unique across sources and filesystem safe.

| Source             | fic_id                        | canonical uri                                | chapter_id |
|--------------------|-------------------------------|----------------------------------------------|------------|
| Royal Road         | `107917` (unchanged)          | `https://www.royalroad.com/fiction/107917/`  | RR chapter id |
| Patreon collection | `patreon-col-1522125`         | `https://www.patreon.com/collection/1522125` | post id    |
| Patreon creator    | `patreon-v-u84402213` (vanity, downcased) | `https://www.patreon.com/u84402213/posts` | post id |

`fic_info.json` gains optional keys; absence means Royal Road, no migration:

```json
"source": "patreon",
"uri": "https://www.patreon.com/collection/1522125",
"source_ref": { "campaign_id": "9755002", "collection_id": "1522125", "vanity": "u84402213" }
```

Chapter files gain `chapter_id`, `source` and `published_at`. Old RR files
have none of these; `Chapter.from_disk_content` falls back to the URL regex.
`volume_id` stays nil for Patreon, which `Epub` already handles.

Chapters stay write-once (as for RR). For this collection that is a
feature: a chapter pulled before the creator stubs it keeps its text; a
late follower gets the stub. Stubs are kept as chapters so numbering stays
intact. Optional later: flag chapters under 100 words in `report`.

### Source abstraction (`lib/peasant_path/sources.rb`)

```ruby
PeasantPath::Sources.resolve(url)
# => { source: "royalroad", fic_id: "107917", uri: "https://www.royalroad.com/fiction/107917/" }
# => { source: "patreon", fic_id: "patreon-col-1522125", uri: ..., source_ref: { collection_id: "1522125" } }
# raises Library::InvalidURL otherwise
```

Accepted Patreon URLs: `/collection/<id>` (query string ignored),
`/<vanity>`, `/c/<vanity>`, `/cw/<vanity>`, `/<vanity>/posts`. Creator
URLs need the network to map vanity to campaign id; `follow` stays offline
by using a provisional `patreon-v-<vanity>` directory and letting the first
pull fill in `source_ref.campaign_id`. Collection URLs are exact at follow
time.

Both clients expose the same three calls, which `Library#pull_fic` uses
through `@clients.fetch(fic.source)`:

- `fic_info(fic)` -> `{ title:, author:, description:, cover_image:, volumes:, volume_covers:, source_ref: }`
- `chapter_overview(fic, known_ids:)` -> `[Chapter]`
- `enrich_overview_chapter!(chapter)` -> fills `chapter_text`, `chapter_title`, prev/next

For Patreon the list endpoint already carries the body, so
`chapter_overview` returns chapters with text filled in and
`enrich_overview_chapter!` is a no-op. The `known_ids:` argument lets the
Patreon client stop paginating (see below); the RR adapter ignores it.

`RoyalRoadClient` keeps its current methods; a thin adapter satisfies the
interface so existing RR specs stay untouched. `Chapter.new` changes to
keyword args (`fic_id:, chapter_id:, uri:, repository:`); RR URL parsing
moves to `Chapter.from_royalroad_url`. `Fic#uri` becomes a stored attribute
with the RR default. `Epub` uses `fic.uri` as identifier and
`chapter.anchor_id` (`rr-ch-<id>` for RR, byte-identical to today;
`pt-ch-<id>` for Patreon).

### Patreon client (`lib/peasant_path/patreon_client.rb`)

Pure Ruby, no browser knowledge. Takes a `transport` answering
`get_json(url)`, `get_text(url)`, `get_bytes(url)`.

Collection pull:

1. `GET /api/collection/<id>` -> title, cover URL, campaign id, `post_ids`,
   `num_posts`.
2. `GET /api/campaigns/<campaign_id>` -> author, description, vanity.
3. Walk `/api/posts` newest first (`sort=collection_order`). For each post:
   skip if `current_user_can_view` is false or the body is empty (log,
   do not persist, so it is retried next pull); otherwise convert and
   collect. Stop after the first page on which every post id is already
   in `known_ids`.
4. `order_number` = position in reversed `post_ids` (drafts leave gaps,
   harmless; a draft published later lands in its slot).
5. Consistency check: if `num_posts` is greater than the known ids that
   are still in `post_ids` plus the new ones, re-walk every page once
   (covers reorders and posts added deep in the list). A post the list
   returns but `post_ids` lacks is deferred to the next pull rather than
   persisted without a slot.

Creator pull: same without the collection call; `order_number` is the
`published_at` epoch, so it never depends on which other posts are visible
(chapters are write-once). Creator feeds always walk every page (no
`post_ids` to anchor on). Acceptable for now.

Errors: `PatreonClient::ScrapeError` (same shape as RR) for missing keys
and malformed `content_json_string`; `PatreonClient::AuthRequired` when
`/api/current_user` is 401, the API answers 401/403, or the page title is
Cloudflare's "Just a moment…".

### ProseMirror to HTML (`lib/peasant_path/patreon_rich_text.rb`)

| Node / mark | Output |
|---|---|
| `doc` | `<div class="chapter-content">…</div>` so the existing EPUB pipeline (blank-`<p>` stripping, `to_xhtml`) applies unchanged |
| `paragraph` | `<p>`; `nodeTextAlignment: center` -> `<p style="text-align:center">`; empty paragraph -> dropped (Patreon uses them as spacers; the EPUB CSS already spaces paragraphs) |
| `text` | escaped text, wrapped by marks in a fixed order |
| `bold` / `italic` | `<strong>` / `<em>` |
| `hardBreak` | `<br/>` |
| `heading` (attrs.level) | `<h3>`..`<h6>` (level + 2, clamped) so chapter titles stay the only `<h2>` |
| `horizontalRule` | `<hr/>` |
| `bulletList` / `orderedList` / `listItem` | `<ul>` / `<ol>` / `<li>` |
| `blockquote` | `<blockquote>` |
| `image`, `video`, `audio`, `embed`, `file` or any other non-text node | `<p><em>[<node type> omitted]</em></p>`, plus a warning in the log naming the post |
| unknown structural node with children (e.g. `blockquote`, `bulletList`, `heading`) | render children as paragraphs and warn; never raise on a single post |
| post with no text after conversion | dropped, logged, not persisted |

Spec with a hand-written fixture that covers every row above plus nested
marks. Word count: existing `WordCounter.count_html` works as is.

### Browser session (`lib/peasant_path/patreon_session.rb`)

The only file that requires `playwright`. Lazily required on first use.

- Profile dir `~/.config/peasant_path/patreon/profile/`, a persistent
  context, so `session_id` **and** Cloudflare's `cf_clearance` survive. A
  fresh context restored from `storage_state` loses the clearance.
  Top-level, outside any fic dir, so `list_chapters` is unaffected.
- `PatreonSession.login`: `launch_persistent_context(profile, headless: false)`,
  open `https://www.patreon.com/login`, poll `context.cookies` each second
  until a `session_id` cookie for `.patreon.com` exists (10 min timeout),
  confirm with `/api/current_user`, close.
- `PatreonSession.open(headless: true) { |transport| … }`: same profile,
  `channel: "chromium"` (new headless) with `userAgent:` set to the headed
  Chrome string for the bundled Chromium version (see Phase 0 gotchas),
  navigate once to `https://www.patreon.com/` so in-page `fetch` is
  same-origin, then serve
  `get_json`/`get_text`/`get_bytes` via `page.evaluate` (`get_bytes`
  returns base64, decoded in Ruby). One browser per `pull_all`.
- CLI discovery, in order: `PEASANT_PATH_PLAYWRIGHT_CLI`,
  `./node_modules/.bin/playwright-core` next to the Gemfile,
  `playwright-core` on PATH. Missing -> `PatreonSession::NotInstalled`
  with install instructions in the message.
- Throttle: with the existing `throttle` flag, 2 to 5 s between API pages.

Alternative considered: `ferrum` (Chrome over CDP, no Node). Fewer moving
parts; revisit only if the Node toolchain proves painful.

### Library, CLI, web

- `Library.new(…, clients: { "royalroad" => …, "patreon" => … })`; the
  existing `client:` kwarg stays as an alias for the RR entry.
- `Library#pull_all` opens one `PatreonSession` lazily on the first Patreon
  fic and closes it in `ensure`. `AuthRequired` becomes a per-fic pull-log
  error: `Patreon login required: run 'peasant_path patreon login'`.
- CLI: `add` accepts Patreon URLs. New Thor subcommand group `patreon`
  with `login`, `status` (logged-in user or "not logged in"), `logout`
  (deletes the profile dir).
- Web: `/follow` accepts Patreon URLs; placeholder text updated; index
  shows the source next to the author. Login stays CLI-only.

## Phases

Each phase ends with `bundle exec rspec` green and `bundle exec rufo .`.

### Phase 0: spike (done 2026-10-12)

Verified with a throwaway playwright-ruby-client script (scratchpad, not
committed): a headful `launch_persistent_context` login into a dedicated
profile dir, then a **headless** relaunch from the same profile. Result:
landing page `Home | Patreon`, `/api/current_user` 200, a full
`/api/posts` page with 20 of 20 posts viewable and carrying bodies, no
Cloudflare challenge, and the `session_id` cookie (one-year expiry on
`www.patreon.com`) still in the profile afterwards. Repeated runs behave
the same. Headless is therefore the default for pulls.

Gotchas found, all of which the implementation must handle:

- **User agent.** New headless Chromium (`channel: "chromium"`) announces
  `HeadlessChrome/156` in its UA. A run with that UA and no session got a
  `Just a moment…` interstitial. Pass `userAgent:` with the matching
  headed string (`Chrome/156.0.0.0`), derived from the Chromium version at
  runtime rather than hard-coded.
- **String keys.** `context.cookies` and `page.evaluate` results come back
  with string keys, not symbols.
- **Clean shutdown matters.** Chromium batches cookie writes; a login run
  whose browser was killed had no `session_id` on disk. Always close the
  context through the block form and never `pkill` the browser. Remove a
  stale `SingletonLock` before launching if a previous run crashed.
- **Detached launches abort.** A headful login started from a shell that
  exits dies with `net::ERR_ABORTED` on the first navigation; the login
  command must run in the foreground of the user's terminal.
- **Login detection.** Poll `context.cookies` for `session_id` on a
  `patreon.com` domain, then confirm with `/api/current_user` 200 before
  closing. The user may close the window themselves; treat a closed page
  without a cookie as "login aborted".
- `playwright-core install chromium` downloads both the headless shell and
  full Chromium (about 100 MB each); only the full build is needed with
  `channel: "chromium"`.

Fixtures: hand-written, schema-faithful JSON under `data/patreon/` with
two-sentence bodies. Real chapter text is paid content and is not
committed.

### Phase 1: source abstraction, no behaviour change (done)

1. `Sources.resolve`; `Library#validate_story_url` delegates to it.
2. `Chapter.new` keyword args, `from_royalroad_url`, disk fallback;
   `persist` writes `chapter_id`, `source`, `published_at`.
3. `Fic`: stored `source`, `uri`, `source_ref`; `from_disk` defaults to RR.
4. `Epub`: `fic.uri` identifier, `chapter.anchor_id`.
5. `Library#pull_fic` through the client interface; RR adapter.
6. Specs: existing ones pass; add round-trips for old-format chapter files
   and fic_info without `source`.

### Phase 2: PatreonRichText and PatreonClient against fixtures (done)

Converter spec per the table. Client spec with a fake transport: collection
metadata, campaign id from thumbnail URL, two-page pagination with early
stop on `known_ids`, `num_posts` mismatch triggering a full walk,
`current_user_can_view: false` skipped, empty body skipped, order from
`post_ids`, creator feed ordering, `AuthRequired` on 401/403 and on a
challenge page, vanity resolution with the escaped-quote regex.

### Phase 3: PatreonSession (done)

Gemspec `playwright-ruby-client ~> 1.64`; `package.json` pinning
`playwright-core` to `Playwright::COMPATIBLE_PLAYWRIGHT_VERSION`;
`bin/install_system_dependencies` gains `npm install && npx playwright-core install chromium`.
`login`, `open`, transport, CLI discovery, `NotInstalled`. Manual test plus
a spec tagged `:browser`, excluded by default in `.rspec`.

### Phase 4: integration (done; web UI not yet exercised by hand)

Client map and session lifecycle in `Library`, CLI `add` and `patreon`
subcommands, web follow form, pull-log wording. End to end against
collection 1522125: `add`, `pull`, `build`, open in Apple Books, check
epigraph centring, italics, chapter order and that the stubbed chapters
appear as short chapters. Library/web specs use a fake Patreon client,
same pattern as `mock_rr`.

### Phase 5: polish (README done; rest open)

README section. The container stays RR-only: Patreon fics inside it fail
with the clear `NotInstalled` message and the README says so.

## Decisions (2026-10-12)

- **No container support for Patreon.** Host only; the container keeps
  working for RR fics and reports `NotInstalled` for Patreon ones.
- **Non-text posts:** dropped when they contain no text; otherwise their
  non-text elements are replaced by a minimal text-only placeholder. Same
  rule for creator feeds and collections.
- **No arcs-as-volumes for Patreon fics.** Patreon fics always have an
  empty `volumes` array and a single combined EPUB.

## Risks

- Cloudflare passed headless Chromium in the spike, but that can change.
  Keep the headful fallback (`headless: false`) one flag away and surface
  a `Just a moment…` landing title as `AuthRequired` with a hint to try it.
- The private API can change without notice. Every missing key raises `ScrapeError`
  naming what broke, so the pull log says so; unexpected ProseMirror nodes
  degrade to placeholders with a warning instead of failing the pull.
- Node and Chromium are a ~400 MB install. Kept strictly optional.
- `session_id` expires after weeks; `patreon status` and the pull-log
  message make re-login a one-command fix.

## Implementation notes (2026-10-12)

- Files: `sources.rb`, `royal_road_source.rb` (adapter), `patreon_client.rb`,
  `patreon_rich_text.rb`, `patreon_session.rb`; `Chapter`, `Fic`, `Epub`,
  `Library`, `CLI` (`patreon login|status|logout`), `Web`/`index.erb`
  (source label, placeholder). Specs: `sources_spec`, `patreon_*_spec`, plus
  additions to chapter/fic/library specs. 212 examples green; the one
  browser-backed example is tagged `:browser` and excluded by default.
- Deviations from the design above:
  - Cover bytes can't be read with in-page `fetch` (the CDN has no CORS
    headers); `PatreonSession::Transport#get_bytes` navigates a throwaway
    tab instead and forces a PNG/JPEG `Accept` header, because the CDN
    otherwise serves WebP for `.png` URLs.
  - The headed user agent is read from a throwaway headless launch and
    `Headless` stripped, instead of being derived from a version string.
  - `Library` builds a `PatreonClient` per pull around one browser session
    (`with_patreon_client`); specs inject `patreon_client:` directly.
- Observed on the real collection: 164 of 563 chapters are the creator's
  Kindle stubs (`[Removed per stubbing for Kindle Unlimited Release]`),
  kept as short chapters as designed. Only headings, rules and lists showed
  up beyond the base schema; all now render natively.
- Review pass (Opus, 2026-10-12) applied: login verified once per session
  (`PatreonClient#verify_login!`), profile lock only cleared when its pid is
  dead (`PatreonSession::Busy` otherwise), empty paragraphs dropped, creator
  order numbers are `published_at` epochs, unslotted posts deferred, re-walk
  only when the collection holds more than we do, `Sources::INFO` registry
  replaces per-site ternaries, `Sources::InvalidURL` aliased as
  `Library::InvalidURL`, `Library` takes `patreon_session:` instead of a
  test-only client, one log entry per fic even when the session dies late,
  gem pinned `~> 1.64.0` to match the Node driver, Linux `install-deps`,
  `/user?u=` and case-insensitive vanities accepted.
- Royal Road behaviour that changed on purpose: URLs without `www.` or a
  trailing slash are now accepted (http or https only); `fic_info` is
  fetched before the chapter list; fics are pulled grouped by source;
  `fic_info.json` gains `source`, `uri`, `source_ref` (absent means RR).
- Pre-existing, left alone: `Epub.format_chapter_in_xhtml` tries to drop
  `&nbsp;`-only paragraphs with `el.text.strip == " "`, which never matches.
  Fixing it changes RR output, so it is out of scope here.
- Cold bootstrap (2026-10-12): `patreon export [FILE]` writes the
  profile's patreon.com cookies (owner-only file) and `patreon import FILE`
  loads them into a fresh profile and confirms the login, for machines with
  no display. Verified live: export from the spike profile, import into an
  empty dir, status logged in on a later open. Copying the whole state dir
  also works because Playwright's Chromium does not use the OS keychain.
- Gem installs (2026-10-12): an installed gem has no checkout to `npm
  install` in, so `patreon status` failed with the install hint.
  `peasant_path patreon install` now puts the pinned driver and Chromium
  under `~/.config/peasant_path/patreon/driver/`, which the driver lookup
  checks before the checkout and PATH. Verified with the installed gem.
- Still open: hand-test the web UI follow/pull path with a Patreon URL;
  `patreon login` has only been exercised through the spike script, not the
  CLI command; the consistency re-walk triggers on every pull of a
  collection that has permanently non-viewable posts (correct, just slower).
