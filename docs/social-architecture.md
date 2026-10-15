# Social system architecture

Status: written before implementation (October 13, 2026) and updated to match what was
built. "Implemented", "tested", and "deployed" are tracked separately at the end of this
file. Migrations 011 and 012 were applied to the live Supabase project on October 13, 2026.

Scope: mutual friendships, reader search, visitor library-card details, Community
(Friends · Feed), reading activity, and Discover → Friends. Out of scope: follows,
suggestions, contacts, likes/comments, notifications, public Archive tabs.

## What exists and is reused

| Need | Existing piece reused | Change |
|---|---|---|
| Identity, username | `textual_profiles` (owner-private, unique normalized username) | Adds owner-only privacy columns |
| Public card + shelf | `textual_reader_profiles` projection, `PublicReaderProfilePage`, `ReaderLibraryCard`, `ReaderBookshelf` | Page/card take a selected reader and optional stat taps; no second design |
| Owner preview (eye) | `ReaderProfileView` → sheet → `PublicReaderProfilePage` | Unchanged route; now masks stats the owner hid |
| Reading state | `textual_library_entries.reading_data` (status, periods, readCount, journal.quotes) via `textual_sync_library` | Sync change may carry activity intents |
| Stats rules | `ReadingStatsFilter.completedCount`, `GenreStat.counts`, `ReadingBookSnapshot.genres` | SQL port of `completedCount`; genre breakdown computed by the same Swift code |
| Reviews | `textual_reviews` via `textual_save_review`, `ReaderReviewEditor`, `ReaderReviewContentView` | Save may carry an activity intent; editor exposes the existing `visibility` field |
| Quotes | `ReadingJournal.quotes` inside `reading_data`, `ReadingQuoteCard` | Card gets a read-only mode |
| Covers / grid | `BookCoverImage` (Nuke), `MasonryGrid`, `DiscoverFeedPage`, `DiscoverCoverCell`, `HoldSlideSource` | Friends tab populated, no visual change |
| Tabs | Discover's tab bar (The Archive tab) | Extracted to `TextualTabBar`, used by Discover and Community |
| Stats popups | `StatsCategoryBooksView` layout, `GenreStatsChart` | Visitor variants composed from the same grid/chart; chart drill-down optional |
| Sync/outbox | `LibraryRepository` frozen payloads, `ReaderProfileStore`, `ReaderReviewStore` | Carry pending intents; no new sync engine |
| Account isolation | `AccountLibraryHost` keyed by user ID; per-account SwiftData store | New `SocialStore` lives and dies with it |

## Schema changes (migrations 011 and 012)

Additive only. No existing column, row, policy, or book identity is removed.

- **`textual_profiles` privacy columns** (reuse existing settings storage):
  `activity_sharing` (default true), `sharing_version` (bumped whenever sharing
  changes), `books_read_visible`, `genres_visible`, `rereads_visible`.
  Visibility columns are added with default **false** so every existing account
  starts hidden (its read list was never public), then the default switches to
  **true** for profiles created afterwards (agreed defaults for new profiles).
- **`textual_friendships`**: one row per unordered pair (`user_low < user_high`,
  primary key). `status` ∈ none/pending/accepted, `requester_id`, `request_id`
  (new UUID per request generation), `version`, timestamps, and a small per-pair
  request counter. Needed because no relationship table exists.
- **`textual_social_operations`**: idempotency ledger for friendship mutations,
  same pattern as `textual_sync_operations` / `textual_review_operations`.
- **`textual_social_rate_limits`**: one fixed-window counter row per
  (user, action) for search and friend requests. Needed because Supabase has no
  per-RPC limiter and client debounce is not a limit.
- **`textual_library_entries.completed_reads`** (011): a stored generated column,
  `textual_completed_count(reading_data)`, plus a covering partial index on
  `(user_id, lower(title), id) include (completed_reads) where deleted_at is null and
  completed_reads > 0`. It's computed once per write instead of once per row per read. The
  first measurement, evaluating the function per row, took 17–20 ms for a 40-book library.
  If the function ever changes, recompute the column.
- **`textual_activity`** (012): one small row per published-or-refused action.
  Columns: actor, transition ID (client UUID, unique per actor), kind, canonical
  `book_id` (FK `textual_books`), and exactly one source reference: library entry
  (+ quote ID / read number), review (FK `(actor, work)` → `textual_reviews`), or
  shelf owner (FK → `textual_reader_profiles`) + favorite ID. `eligible` is fixed at
  insert. `occurred_at` is display-only; `published_at` is server time and orders
  the feed. No text, rating, notes, or images are copied into the row.

## API (all `security definer`, `search_path = ''`, `auth.uid()` checked inside)

| RPC | Purpose |
|---|---|
| `textual_social_settings()` / `textual_update_social_settings(...)` | Owner reads/changes privacy; nobody else can |
| `textual_search_readers(query, cursor, limit)` | Name/username prefix search, viewer excluded, ≤ 30 per page, rate-limited; returns public identity + the viewer's own relationship only |
| `textual_update_friendship(expected_user, operation_id, action, target, request_id)` | send / accept / decline / cancel / remove; row lock + request-ID guard + ledger |
| `textual_list_friends(cursor, limit)` | Viewer's friends and pending requests only |
| `textual_read_public_profile(username)` | Card + shelf with hidden stats removed, server-computed counts, relationship |
| `textual_read_profile_books(username, list, cursor, limit)` | Books read / rereads, keyset-paginated, rechecked every page |
| `textual_read_feed(cutoff, cursor, limit)` | Accepted friends' eligible activity, rendered from current sources |
| `textual_read_friend_discovery(snapshot, cursor, limit)` | Discover → Friends candidates from permitted sources |
| `textual_sync_library` (replaced) | Accepts optional `activity` intents per change |
| `textual_save_review` / `textual_publish_reader_profile` (re-signed) | Accept optional `p_activity` (defaulted, so current app versions keep working) |
| `textual_read_reader_profile` (replaced) | Old-client path: owner unchanged; others get hidden counts as 0 and no breakdown |
| `textual_social_settings` (012 version) | Adds `activityEnabled: true`. The app stamps intents only after seeing it, so it never sends `activity` to a database without 012 |

Abuse limits (server-side, fixed windows): 60 searches per minute per account; 30 friend
requests per hour per account; 3 requests to the same reader per 7 days. Exceeding a limit
raises SQLSTATE `PT429`, which the app shows as "Try again in a moment." Searches need at
least 2 characters, and each page returns at most 30 results.

`security definer` is required because each read is a controlled projection across
owner-private tables (library entries, reviews, profiles) that RLS correctly keeps
closed. New tables have RLS enabled and **no** client grants; private helpers have
execute revoked from `public`, `anon`, `authenticated`, and `service_role`.

## Permission matrix (enforced in SQL; tested under the real `authenticated` role)

| Data | Owner | Accepted friend | Other signed-in | Signed out |
|---|---|---|---|---|
| Card + shelf | full | public fields | public fields | none |
| Enabled card detail (list/breakdown/count) | yes | yes | yes | none |
| Disabled card detail | yes | **no** | **no** | none |
| Private archive, notes, progress, private reviews | yes | no | no | none |
| Activity | own | only while friends **and** actor sharing on **and** source still visible | no | none |
| Friendship row | participants via RPC | own relationship | no | none |
| Privacy settings | read/write | no | no | none |

Leak rules: a disabled statistic returns neither its count nor its list nor its
breakdown from any endpoint. The feed returns `read_number` only while the actor shows
Rereads. Otherwise it returns an opaque `read_key` (md5 of entry + read number), so the app
can keep separate reads apart without learning a count. Because reads include rereads, when Rereads is hidden
the visitor's Books Read number is the count of **distinct** books (otherwise
`reads − books` would reveal rereads) and genre counts use books, not reads.
Ratings never ride along with Books Read. Every returned book carries its
permission source (`books_read`, `rereads`, `shelf`, or the activity kind).

## Stats definitions (no new semantics)

- Completed reads per entry = `ReadingStatsFilter.completedCount` (ported to
  `textual_completed_count`): `max(readCount, valid finished periods, status==read)`,
  zero when `readCount == 0` and not read. Removed entries are excluded. Editions
  are separate entries, so a second edition is never a reread.
- Books Read list = live entries with completed count ≥ 1; Rereads = ≥ 2;
  title order with ID tie-break (as the Stats popup sorts). Counts and lists come
  from the same query, so they cannot disagree.
- Genres stay catalog-owned and are classified **on device** (catalog evidence +
  `GenreTaxonomy`), not on the server. The owner's device computes the breakdown
  with `GenreStat.counts` over **known** genres (empty → "Unclassified", exactly the
  card's existing "known genre count" rule) and publishes it inside the existing
  validated card projection. The server only stores and permission-filters it.
  A fully server-side breakdown would require moving catalog classification to the
  server; that is a catalog rewrite and out of scope.

## Activity generation

Intent + server-verified transition, in the source mutation's transaction:

1. A user action (start, finish, save quote, publish shared review, add to shelf)
   appends an intent `{id, kind, shared, sharing_version, occurred_at, ref}` to the
   local record **in the same SwiftData save** as the mutation, so it rides the
   existing frozen outbox payload. Imports, downloads, conflict merges, queue
   reorders, progress updates, and edits create no intents.
2. The existing RPC (`textual_sync_library`, `textual_save_review`,
   `textual_publish_reader_profile`) applies the change and then, in the same
   transaction, verifies each intent against old → new state: started requires
   entering currently-reading (or a completion in the same change); finished
   requires the completed count to rise (each intent takes the next read number,
   so rereads stay distinct); quote requires a quote ID that did not exist before;
   review requires entering shared visibility; shelf requires a newly added
   favorite. Unverifiable intents are ignored, never fatal to sync.
3. Insert is `on conflict do nothing` on `(actor, transition_id)` plus per-source
   uniqueness (one event per quote, per review, per read number). Replays of the
   same operation return the ledger result before any write. A crash after commit
   is therefore safe: the retry is either deduplicated by operation ID or by
   transition ID.

## Sharing lifecycle

- `eligible` = intent was stamped shared **and** its `sharing_version` equals the
  server's current version **and** sharing is on, evaluated under a row lock on the
  owner's profile. Any toggle bumps the version, so an action queued before a
  toggle (even off → on) can never become eligible later.
- The device stamps intents only when settings were loaded from the server, the
  database advertises `activityEnabled`, sharing is on, and no settings change is
  waiting to upload. Otherwise it creates no intent: unknown or uncertain intervals
  never publish.
- Reads additionally require the actor's **current** sharing to be on, so turning
  sharing off hides earlier activity immediately; turning it back on restores only
  rows that were eligible when created. No backfill of archives, reviews, or quotes.
- Card visibility and shelf curation are independent of sharing; the shelf remains
  what the reader chose to display.
- Reviews follow their own `visibility` field (`public` = may appear to friends).
  Existing reviews stay private. New reviews start shared only if activity sharing
  is on; the editor shows and controls this.

## Feed

Stored once, queried at read time (no per-recipient copies). Keyset pagination on
`(published_at, id)` below a client-held session cutoff; page 25, server max 50;
each page re-derives friendships and settings. Two phases keep it bounded:

1. For each sharing friend, the newest eligible events are scanned on
   `textual_activity_feed`. Their sources are confirmed with `EXISTS` lookups. Only quote
   events read `reading_data`.
2. Display content (actor, book, quote text, review) is built only for the chosen page,
   from the current sources.

Edits update in place, and deletions or privacy changes remove the event. One request
returns everything for the page. Building content for every friend's top 26 before choosing
the page was measured at 41 ms; the two-phase version is 6 ms.

Grouping happens on device over raw events (raw events preserved): same actor +
same book within 12 hours, at most one started/finished/review per group, quotes
kept individually. Each event only joins a group created by earlier (newer) events,
so appending a page never reorders cards already on screen.

## Discover → Friends

Candidates: friends' curated shelves (independent of sharing), and — only while the
friend shares activity — started/currently reading, finished, and shared reviews
rated ≥ 4★. Score = Σ source weight × 30-day half-life decay (shelf: weight 3, no decay;
review 4; started/finished 2) + 1.5 per additional distinct friend. Decay is computed
relative to the session snapshot, and each contribution is rounded to 6 decimals before
summing. That makes the score exact and order-independent, so the `(score, book_id)` keyset
cursor round-trips. Entry lookups are split into two exact index joins. An `OR` join
measured 598 ms; the split version is 60 ms. Books in the viewer's own archive are
excluded (as For You does). Hidden sources never contribute because they are never
selected. Friendship removal or sharing off removes those contributions on the
next page. No fake activity; empty states route to Community.

## Client cache boundaries

- `SocialStore` is created per account inside `AccountLibraryStore` and stopped on
  sign-out/account change (host is keyed by user ID). Every request captures a
  generation; late responses after stop or switch are discarded.
- Friend content (profiles, lists, feed, discovery, avatars) is **memory only**,
  bounded (profiles: 20 entries, 5-minute TTL; feed ≤ 500 events; discovery ≤ 240
  books; avatars ≤ 50 images) and never written to SwiftData, so it cannot enter
  the viewer's archive, Stats, or editing queries.
- Persisted (account store): own privacy settings + pending change, and pending
  intents on the viewer's own records.
- Revalidate on open, foreground, and pull-to-refresh; no polling or realtime
  subscriptions. Content already shown on a device cannot be remotely erased while
  that device stays offline; after restart nothing friend-related remains.

## Migration, compatibility, deployment

1. Apply `011_social_graph.sql`, then `012_social_activity.sql`. Each is one transaction,
   additive, and refuses to run twice. Current app versions keep working: new parameters
   are defaulted, and the old profile read path filters hidden stats. 011 alone is a safe
   stopping point. It accepts the genre breakdown, and the app sends no activity until 012
   advertises `activityEnabled`.
2. Ship the client. It also keeps working against a database without either migration. Its
   settings load fails, so it sends no intents and no breakdown.
3. Verify with a second account: send and accept a request, save a quote, and check the Feed
   and Discover → Friends.
4. Roll forward with a new migration rather than editing applied ones. To disable social
   reads without touching library data, revoke execute on the social read RPCs.

Locks: 011 adds a stored generated column, which rewrites `textual_library_entries` under
an exclusive lock. On the current project, this table is small. 011 also creates three
indexes without `concurrently` (one transaction).

Account deletion: every new row references `auth.users` (or a table that does) with
`on delete cascade`.

## Decisions to confirm (flagged, not guessed)

- **Existing accounts start with Books read, Genres, and Rereads hidden.** This is stricter
  than before: their counts were visible on the card. Their read lists were never public, so
  each owner opts in. A hint on Profile links to the setting.
- **Genre breakdown is computed on the owner's device**, with the Stats code, and published
  inside the validated card projection. It is not computed on the server, because catalog
  classification lives on the device. The server stores it and filters it by permission.
- **New reviews default to shared while activity sharing is on**, using the existing
  `visibility` field. Existing and imported reviews stay private. The editor shows the switch.
- **Search returns `user_id`.** Friendship operations need a stable target that survives
  username changes. No email, settings, or graph data is returned.
- **Name search is case-insensitive prefix matching.** It doesn't fold accents, which would
  need `unaccent`. There's no contacts sync or suggestions.
- **No realtime.** Refresh happens on open, foreground, and pull-to-refresh. Incoming requests
  appear on the next refresh.

## Status (October 13, 2026)

| | State |
|---|---|
| Implemented | Migrations 011/012; Swift models, transport, `SocialStore`; Community (Friends, Feed); visitor profiles with stat popups; privacy settings; Discover → Friends; activity intents in library, review, and card outboxes; DEBUG harness |
| Tested locally | `supabase/tests/social.test.mjs`: 191 checks on disposable PostgreSQL 18, in three scenarios: existing data then migrate, 011-only staged, and fresh. Includes real two-connection races and a mutation check (three injected bugs, each caught). Migrations and core RPCs smoke-tested on PostgreSQL 16.4 (PGlite). `textualTests/SocialTests.swift`: 23 tests, including a wire contract shared with the SQL suite. `CommunityUITests`: 5 UI tests on an iPhone 17 simulator |
| Measured | Synthetic local data only: 3,000 readers, 900k library rows, 150 friends each, 360k events. Medians: feed 5.9 ms, profile 0.2 ms, Books Read page 0.3 ms, search 0.3–0.6 ms, friends list 8.3 ms, Discover → Friends 60 ms, sync with an intent 1.4 ms. This is a laptop measurement, not a production capacity claim |
| Deployed | **Backend only.** 011 and 012 applied to the live project in the SQL Editor on October 13, 2026; a read-only check afterward confirmed all 12 RPCs exist, run for `authenticated` and not `anon`, and the 4 new tables exist. No build is distributed |
