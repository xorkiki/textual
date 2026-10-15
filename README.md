# Textual

A modern, local-first book tracking and social reading app built with Swift and SwiftUI.

## Project Vision

Reading today is fragmented, isolating, and poorly designed. People struggle to meaningfully organize what they want to read, keep track of what they are actually reading, and discover books through taste-aligned signals rather than noisy algorithms. Most existing book apps are cluttered, outdated, and visually uninspiring, making the experience feel utilitarian instead of intimate or culturally relevant.

This app solves that by offering a clean, modern, and aesthetically intentional space for reading life. It provides an elegant system for sorting books, lightweight and useful stats, and social discovery grounded in real reading behavior. Long term, it expands beyond the screen to support modern-day reading salons. Through opt-in, location-based discovery, users can find people nearby reading similar books and form small, intentional groups. The goal is to make reading feel beautiful, social, and alive again, rooted in taste, proximity, and conversation rather than performance or scale.

## Features and Product Roadmap

These original feature descriptions remain the product direction. They include planned
behavior; see **Current features** below for what is implemented today.

### 1. Shelf Curation Logic
Create and organize custom shelves with public/private visibility controls. Pre-seeded examples include:
- "books that ruined me"
- "men i should not have dated but did anyway"
- "quiet books"

### 2. User Home & Statuses
Track your reading progress with four distinct statuses:
- **Currently Reading** - Books you're actively reading
- **To Be Read** - Your reading wishlist
- **Read** - Completed books
- **DNF** - Did not finish

Every book displays its last activity timestamp, keeping you aware of your reading patterns.

### 3. Privacy & Social
- **Authentication**: All content is gated behind Email or Apple Sign-In
- **Friends**: Mutual friendships (request and accept) are required to see someone's activity feed
- **Activity Feed**: Track when users start books, finish books, and add books to public shelves

### 4. Book Detail & Notes
Rich book metadata including:
- Title and author
- Cover images loaded via Nuke with intelligent caching and downsampling
- 5-star/numeric ratings
- Mandatory one-line notes for every book

### 5. Offline Behavior
- **Read-only Cached Views**: Browse your library even when offline
- **Queued Actions**: Ratings and shelving actions are queued locally and sync automatically when connectivity is restored

### 6. User-Driven Import (CSV / Export File)
Import your existing book data from other apps:
- **Export Support**: Users can export their data from other book tracking apps (typically as CSV)
- **Upload Options**: Upload CSV files directly or paste a link to the export file
- **Field Mapping**: Automatically parse and map CSV fields to the app's schema
- **Review Before Import**: Preview all imported data on a "review before import" screen to verify accuracy
- **Smart Import**: Import process includes deduplication against existing books and stores source references for traceability

## Tech Stack

The original technology and architecture goals are retained below. Swift 6 is the
intended direction; the current Xcode project uses Swift 5 language mode. Background
actors keep network work off the UI thread, while iOS background delivery remains a
separate capability; current sync behavior is detailed below.

### Core Technologies
- **Swift 6** - Modern Swift with full concurrency support
- **SwiftUI** - Declarative UI framework
- **SwiftData** - Local-first data persistence
- **Supabase** - Backend services (Auth, PostgreSQL, Storage)
- **Nuke** - High-performance image loading and caching

### Architecture Principles
- **Local-First**: All UI reads come from SwiftData `@Query` for instant, offline-capable views
- **Background Sync**: Supabase synchronization happens on a background Actor
- **Repository Pattern**: Abstracts the choice between local and remote data sources
- **Modern Concurrency**: Swift 6 async/await throughout

## Data Models

The original model outline is preserved here as design context. The current implementation
uses dedicated Codable sync payloads and does not enforce a unique ISBN index; the
additional account and import fields are described under **Tech stack and models** below.

### Book
- `id`: UUID (Primary Key)
- `isbn`: String (Unique index)
- `title`: String
- `author`: String
- `coverURL`: String
- `googleBooksVolumeId`: String? (optional – Google Books volume ID for detail fetches)
- `tags`: Many-to-many relationship with Tag

### Tag
- `id`: UUID (Primary Key)
- `name`: String
- `books`: Many-to-many relationship with Book

All models include Codable conformance for seamless Supabase synchronization.

## Performance Requirements

- **Local-First**: All UI reads must come from SwiftData `@Query`
- **Smooth Scrolling**: Use `LazyVStack` and `LazyVGrid` for all lists
- **Background Sync**: Supabase sync must happen on a background Actor

## Code Standards
- Follow architectural patterns in `TECHNICAL_SPEC.md`
- Use modern Swift 6 concurrency (async/await)
- Prefer `@Observable` macros for view models
- Always use `Lazy` containers for scrollable content
- Keep view bodies lightweight; move heavy logic to Service classes

## Current features

- Email/password signup and sign-in, in-app email confirmation and recovery codes, password reset, and device-local sign-out.
- Private profiles with a first name and a globally unique username.
- A separate local library for each Supabase project and account, with queued book additions/removals and private library sync.
- Explicit conflict resolution and an optional import of the original device library.
- Unified title/author catalog search, paginated results, book details, and cached covers.
- Discover (The Archive tab): For You, Trending, Explore, and Friends as cover-only masonry grids. Tap opens details; hold and slide saves or updates a book. See [Discover](#discover).

StoryGraph CSV imports preserve and sync private reading statuses, dates, ratings, reviews, and export metadata. Custom shelves, Apple Sign-In, and the Reader remain planned; friendships and the Community feed are described under [Community and friends](#community-and-friends). Imported tags are preserved as metadata; custom shelf membership is not yet synced.

## Navigation and next pages

After signing in and completing a profile, the app opens **The Archive**. Its bottom navigation is an icon-only capsule with a wider oval highlight for the selected tab (#4C1308 at 30%). Its charcoal fill (#232323 at 35%) matches the dark login button, without an outline, with #8C8C8C icons in this order: Home, My Archive, The Archive, Stats, Menu. My Archive retains the book grid, add/search sheet, details, and sync controls. Existing account settings and device-library import are available through Menu → Account. Home, The Archive, and Stats are placeholders; their features are deliberately deferred.

Book cards align at the top of each row and reserve two lines for titles so covers and author labels line up. Books scroll behind the compact header and bottom menu, fading beneath those controls. Content padding keeps the first and last rows readable at rest without the extra large-title gap. Library and search scroll indicators are hidden. Search begins at three characters, matching the catalog's minimum, with an inline hint for shorter input.

Page direction saved from Kiki’s October 8, 2026 request (future work):

| Page | Planned purpose |
|---|---|
| Home | Profile, current read, and an up-next pile |
| My Archive | Saved books and custom categories |
| The Archive | Discover: suggested reads, plus what friends are reading on the Friends tab |
| Community | Friends (search, requests, friends) and Feed (friends' reading activity) |
| Stats | Personal reading statistics |
| Menu | Miscellaneous things people can access |

## Accounts and profiles

Signup follows welcome → email → password → first name → username, using Textual’s fonts and palette with rounded action buttons. With email confirmation enabled, creating an Auth user does not open the library. The first name and username are saved as suggestions in Auth metadata; a username is not reserved during signup.

After confirmation or sign-in, `AccountSession` fetches the authenticated user's private `textual_profiles` row. Existing profiles are reused. If no row exists, the user explicitly completes their profile using the prefilled suggestions. The `textual_upsert_profile` RPC claims the normalized username atomically; a collision asks the user to choose another name. A failed profile lookup shows a retry screen rather than assuming the profile is missing.

`ContentView` opens the signed-in tabs only after session restoration, profile loading/completion, and any password recovery are finished. Supabase stores credentials in its Keychain-backed storage.

New confirmation and password-reset emails contain a code to enter in Textual. Read the email on any device, then enter the code in the app running on the iPhone or Simulator. The signed-out sign-in screen offers “I have a confirmation code”; the forgot-password screen offers “I have a recovery code.” These routes do not send email. Code entry supports retry and an explicit resend action. Email/password sign-in is unchanged, including for an account already confirmed using an older email link.

The following allowlisted PKCE callbacks remain supported for older emails; links are no longer the default in new confirmation/recovery templates:

- `textual://auth/callback`
- `textual://auth/recovery`

The email sender is configured separately from the app. **Live signup and password recovery with the new code emails still require end-to-end verification.** Automated checks validate navigation and mocked Auth responses, not real email delivery or a real code exchange.

## Local storage and sync

Library views read SwiftData through `@Query`. `AccountLibraryStore` opens an account-specific store under Application Support at `Accounts/<project-host>/<user-id>/library.store`. Signing out stops synchronization and releases the visible store; it preserves that account's local books for a later sign-in.

`LibraryRepository` saves each mutation with an operation ID and a frozen retry payload. `SupabaseLibrarySyncTransport` performs network work on an actor. Sync runs when the library opens, after supported mutations, on foregrounding/reconnection, or through Retry. Each request sends up to 50 changes and pulls up to 200 entries; one run is bounded to five requests, so large backlogs may need another sync.

The server derives ownership from `auth.uid()` and checks the expected account ID. Server revisions detect conflicting changes, operation IDs make retries idempotent, and deletion markers propagate removals. Downloaded entries and the pull cursor are committed together. Conflicts retain the local version until the user chooses which version to keep.

The original pre-account library is preserved. Import requires an explicit confirmation and copies books into the chosen account; it is offered once per project on that device and never silently uploads existing books. Missing catalog references may require a network lookup before import finishes.

An already-open library can use saved books offline and retain queued changes. A fresh launch still needs a successful profile lookup before entering the library; profiles are currently held in memory, not persistently cached. Sync is foreground work, not a promise of background delivery while iOS suspends the app.

## Tech stack and models

- **SwiftUI** and `@Observable` services/view models, with async/await.
- **SwiftData** for `Book`, `Tag`, and account-local `LibrarySyncState`.
- **Supabase Auth/PostgreSQL** for accounts, private profiles, and private library sync.
- **Nuke** for cover loading, downsampling, and caching.

`Book` keeps its local UUID stable, stores a catalog ID in the legacy `googleBooksVolumeId` property, and has optional detail-cache fields. Additive sync fields track the server entry/book IDs, server revision, pending operation/payload, conflict snapshot, and deletion state. `LibrarySyncState` stores the account's pull revision. Network payloads use dedicated Codable DTOs rather than serializing a SwiftData model context.

The shared `textual_books` table contains catalog identity only. User-provided title/author/ISBN/cover snapshots live in owner-private `textual_library_entries`. Row-level security protects profiles and library rows; authenticated writes use the validating RPCs.

## Development

### Setup

1. Open `textual.xcodeproj` in Xcode and resolve Swift packages.
2. Copy `textual/Secrets.example.xcconfig` to `textual/Secrets.xcconfig`, then configure `SUPABASE_URL` and `SUPABASE_ANON_KEY` in the local `textual/Secrets.xcconfig`. Use the project's public publishable key or legacy `anon` key. An `.xcconfig` URL must escape its double slash, for example `https:/$()/your-project.supabase.co`.
3. For a new backend, apply `supabase/migrations/001_textual_accounts.sql`, `003_textual_profiles.sql`, then `004_storygraph_import.sql` in order. These migrations are already applied to the existing project; do not rerun them there. Ensure the backend has `textual_profiles`, `textual_books`, `textual_library_entries`, and the `textual_upsert_profile` / `textual_sync_library` RPCs with their RLS policies. Keep email confirmation enabled and retain both callbacks above in Supabase's redirect allowlist for compatibility.
4. Configure the email sender and apply `supabase/templates/confirmation.html` with subject **Confirm your Textual email**, and `supabase/templates/recovery.html` with subject **Reset your Textual password**. These templates display `{{ .Token }}` as the code to enter in Textual, instead of linking to `{{ .ConfirmationURL }}`. Verify both real email flows from the installed app; the mailbox can be opened on another device.
5. Build and run. Search uses Open Library without a Google Books key, but the library's account gate requires working Supabase configuration.

### Book search

Search has one pill-shaped field for either book titles or author names, with no category selector. General catalog search matches both through the provider’s relevance ranking. Typed scopes remain supported internally by the catalog service, but the screen always uses the general query. If `GOOGLE_BOOKS_API_KEY` is configured in `textual/Secrets.xcconfig`, Google Books is used first; quota, authorization, or server errors fall back to Open Library. Without a key, searches go directly to Open Library. The optional key is read through Info.plist and is never sent to the fallback catalog or logged.

A shared `BookCatalogService` actor owns requests, throttling, and bounded caches. Input is debounced by 300 ms and superseded requests are cancelled. Searches fetch 20 lightweight results at a time; Load more stays on the same catalog and preserves results on failure. Search responses are cached for five minutes (up to 64 pages), and Google failures trigger a five-minute cooldown before retrying that provider. Cancellation does not reserve future request slots.

Book details appear immediately from saved metadata. Fetched detail snapshots are persisted in SwiftData and refreshed after 24 hours; an in-memory cache also avoids duplicate detail fetches. Catalog failures show a retryable message instead of an empty result list. Open Library work IDs use an `openlibrary:` prefix in the existing catalog-ID field, preserving compatibility with saved Google Books IDs. The two optional snapshot fields are additive to the existing local model.

Covers use a shared Nuke pipeline with request cancellation/coalescing, thumbnail decoding, bounded memory caching, and a 100 MB disk cache. First-time searches and uncached covers still depend on the external catalog/network; the app does not run its own catalog backend.

Catalog documentation: [Google Books](https://developers.google.com/books/docs/v1/using), [Open Library search](https://openlibrary.org/dev/docs/api/search).

The prepared catalog Edge Function is not deployed or connected to this client. Catalog requests continue to use the direct provider path described above; account/library sync does not change search routing.

### Tests and code standards

Run `textualTests` and `TextualAuthUITests` in Xcode. The UI tests require a signed-out simulator. They cover form navigation, retained drafts, keyboard layout, both “I have a code” routes, invalid code validation, and Back navigation without creating an account, sending email, resending, or submitting a valid-length code. Auth unit tests use intercepted HTTP fixtures for code verification and recovery; they do not contact live Auth endpoints. Tests also cover profile validation and collisions, account-change races, sync retries/conflicts, catalog behavior, and bundled font loading. These checks do not replace live email delivery and code verification.

Follow `TECHNICAL_SPEC.md`, use `@Observable` and structured concurrency, keep view bodies lightweight, and use lazy containers for scrolling content. SwiftData mutations remain on the model context's actor; network sync uses a separate transport actor.

## Configuration security

Do not commit `Secrets.xcconfig`. Anything bundled in an iPhone app is extractable, so this file must contain only client-appropriate configuration. Supabase publishable/anon keys rely on RLS for authorization. Never bundle a Supabase secret/service-role key, database password, Resend API key, or SMTP password. The optional Google Books key is client configuration and is not a server-side secret.

## License

[Add your license here]

The bundled Plus Jakarta Sans fonts are distributed under the SIL Open Font License; see `textual/Resources/Fonts/PlusJakartaSans-OFL.txt`.


### StoryGraph imports

Menu → Import reading data opens the native CSV picker and a read-only preview.
Confirm to save into the signed-in account’s My Archive. The importer preserves
status, dates and rereads, fractional ratings, reviews, moods, tags, format,
ownership, and all original export columns. Undated reads remain undated; exports
without page counts cannot support page totals yet. The Stats UI is separate.

Importing the same export again skips unchanged books. Matches use import identity,
valid ISBN, then unambiguous title/author; matching books retain their title and cover.
Changed export data replaces prior StoryGraph reading data on those matches.
Conflicting duplicate rows and unresolved library sync conflicts require review.
Files are UTF-8 CSV, up to 10 MB and 10,000 books; individual reading notes up to 64 KB.

Apply `supabase/migrations/004_storygraph_import.sql` after the account foundation
before distributing this client. Reading metadata is stored in owner-private library
entries and uses the existing account assertion, RLS, revisions and durable outbox.
Shared catalog entries contain identifiers only. No personal export is bundled.


### Public reader cards and keeper shelves

Profile replaces the Home tab and opens first. Its full-width library card shows the
account name, username, completed-read count (including rereads), known genre count,
and reread count using the same history rules as Stats. The lowercase reader sentence
is composed on device from completed books’ catalog genres, imported moods, and book
pace. Fewer than three distinct completed books gets a judgment-pending line; missing
metadata is never treated as a known preference. It does not infer actual reading times.

Readers choose up to 15 favorites from My Archive. Only covers appear on the shelf;
tapping opens catalog details. Tap the pencil beside the shelf title to enable editing,
then drag a cover to reorder or onto the trash to remove it. VoiceOver move/remove actions
are available while editing. Tap the checkmark to lock the shelf again; leaving the
profile also exits editing. Changes persist in an
account-local SwiftData draft, retry on foreground, pull to refresh, or Try again, and
use revision checks to avoid silently overwriting another device’s changes.

Apply `supabase/migrations/005_public_reader_profiles.sql` once after 004 to enable
public viewing. A separate validated projection publishes only the card’s aggregate
stats, generated sentence, and selected book metadata. Existing private-table policies
remain unchanged. Profiles are visible to signed-in Textual readers through exact
username lookup from a reader link, consistent with the app’s account gate.
The eye button previews that visitor layout. `textual://reader/<username>` opens a
reader in the installed app; this is not a hosted web profile.


### Library-card profile photos

Tap the rounded plus-sign space on your card to open the native Photos picker;
tap an existing photo to replace it. Only the selected image is read. The app resizes
it to a maximum of 768 pixels and writes a JPEG without EXIF/location metadata.
The selected image and a durable upload flag are saved in the account-local draft.
Upload happens before the public card references the photo; a failed upload remains
queued for Retry, foregrounding, or pull to refresh. A successful upload is reused if
only card publication needs retrying. Public visitor cards show the selected photo
without an editing control.

Apply `supabase/migrations/006_reader_profile_photos.sql` once after 005. It creates
the private `textual-avatars` bucket (JPEG, maximum 2 MB), limits writes to the owning
account, permits signed-in readers to view the current published photo, and validates
photo ownership/existence when publishing a card. Pending and replaced photos stay
owner-only. This migration does not change signup, email verification, or private
library access. Automatic cleanup of replaced photo files is not implemented.

Deployment status for this feature: 005 and 006 are prepared and tested locally;
live application and end-to-end account/photo verification are pending admin access.


### Apply the public-profile backend setup

For the existing Textual Supabase project, open **SQL Editor → New query**, paste the
entire contents of `supabase/setup_public_profiles.sql`, and run it. This combines
005 and 006 in one transaction, checks that the account/library foundation exists,
and can be rerun without deleting saved cards, accounts, or photos. It replaces the
need to apply 005 and 006 separately. Success returns the message "Public profiles
and photo storage are installed. Reopen Profile in Textual and tap Try again."

The app then publishes its queued public card, selected books, and selected photo.
Verify the card from a second signed-in account using `textual://reader/<username>`.
The owner’s eye-button preview confirms layout only; it is not a server-sync check.
This setup script has passed local permission and repeat-application tests. It is
already applied to the live project: a read-only check on October 12, 2026 confirmed
`textual_reader_profiles`, the read/publish/avatar functions, the `textual-avatars`
bucket, and all three avatar storage policies. Do not rerun it there.


## Reviews

Book detail includes Your review with a reusable create/edit sheet. Readers can save
quarter-star ratings, prose, or both, flag spoilers, and continue account-local drafts.
My Archive → My reviews lists saved reviews and drafts with title/author search. Explicit
saves use the account-scoped retry outbox; conflicts require a choice instead of silently
overwriting another device. Removing a review leaves the book in the archive.

See [review architecture](docs/review-architecture.md) for ownership, sync, and reuse.
Migrations `007_reader_reviews.sql` and `008_catalog_owned_classification.sql` passed
40 isolated database checks and were deployed to production with explicit user approval
on October 12, 2026. Live checks confirmed the read/save endpoints, row-level security,
and owner-only access. Imported ratings and review text appear in My reviews and book details, and prefill
the editor. Native saves and withdrawals take precedence; source import data remains intact.


### Public catalog classification

Classification lookup version 4 enriches verified Google search candidates from their
volume detail records, retaining both `categories` and `mainCategory`. Open Library
fallback uses the exact ISBN edition’s subjects and linked works before title/author
search, and retains search subjects when work details are unavailable. Sparse works
also check one cached page of up to 20 sibling editions, accepting subjects only from
entries that explicitly link back to the verified work. Conflicting editions remain
unresolved, and sibling page counts are never used. Unclassified completed books are
processed before already-classified reads and unread books. Audience-only
labels do not stop genre enrichment. Detail requests are bounded and use the shared
background rate limiter. ISBN validation and title/author checks prevent unrelated
results from supplying genres; page counts still require the exact edition.

Existing caches refresh once after the version change. Successful empty lookups use
a daily backoff; outages remain retryable on the next account warmup, and a failed or
skipped Google lookup is not recorded as successfully checked. Partial refreshes
preserve prior verified evidence. These rules apply to every account and contain no
book-specific overrides. Unavailable or conflicting evidence remains unclassified.


Genres and fiction/nonfiction are catalog-owned data, not review questions or community votes.
Migration `008_catalog_owned_classification.sql` updates the review foundation after 007,
accepts review submissions without genre fields, hides legacy classification answers from
review responses and summaries, and exposes only mood terms to the review picker. It is
deployed with 007 as of October 12, 2026. The app also refreshes
incomplete public classifications using verified Google Books and Open Library matches.


## Discover

The Archive tab is Discover: **For You · Trending · Explore · Friends**. Each tab is one
uninterrupted two-column grid of real book covers at their natural proportions, with no titles,
ratings, labels, or rankings. Tapping a cover opens the existing book details. Pressing, holding,
and sliding uses the existing quick-action menu: books not yet saved offer Read, Currently reading,
TBR, and DNF; saved books offer quote, progress, finish + rate, and note. Saving goes through the
existing archive repository and sync, so a discovered book never becomes a second record.

- **For You** ranks on the device from the reader's own archive: shelf favorites (top five weighted
  highest), ratings, statuses, authors, and genres. Ranking is deterministic and needs no AI service,
  and it aims for about 70% personal and 30% exploratory picks. An empty archive gets a diverse mix
  of trending, new, and Explore books, and personalization grows automatically as the archive does.
- **Trending** combines Apple Books charts (and NYT best sellers, if enabled) with normalized
  per-source scores.
- **Explore** interleaves 26 subject, era, and literary-origin pools plus new releases in a
  per-session seeded order.
- **Friends** shows covers from accepted friends' curated shelves and shared reading activity, in the
  same grid; with no friends it says so and links to Community. See [Community and friends](#community-and-friends).

Collections are refreshed by the `discovery-refresh` Edge Function on a `pg_cron` schedule and
cached in the account's SwiftData store. Discover opens instantly from cache, works offline,
and refreshes quietly. Full design, data sources, terms, and ranking rules:
[docs/discovery.md](docs/discovery.md).

### Apply the Discover backend

1. Apply `supabase/migrations/009_discovery.sql` once (after 001 and 007), then
   `010_discovery_service_grants.sql`, in the SQL Editor. Both are applied to the existing project
   as of October 13, 2026.
2. Deploy `supabase/functions/discovery-refresh` with JWT verification **off**. It verifies
   its own caller token, for example:
   `supabase functions deploy discovery-refresh --no-verify-jwt`.
3. Optional function secrets: `NYT_API_KEY` (read the NYT terms in docs/discovery.md first;
   non-commercial only, 24-hour cache limit, visible attribution) and `GOOGLE_BOOKS_API_KEY`
   (a server key restricted to the Books API, not the iOS-restricted app key).
4. Put the project URL into `supabase/setup_discovery_schedule.sql` and run it. It enables
   `pg_cron` and `pg_net`, creates the caller token in Vault, and schedules the three jobs. Run the
   commented first-fill lines to populate collections immediately.

Until the backend is applied, Discover shows a small retry message rather than inventing books.
To check refresh health, run `select * from public.textual_discovery_health();` in the SQL Editor;
`stale` is true when a collection has missed two scheduled refreshes.

### Discover tests

`textualTests/DiscoveryTests.swift` and `textualUITests/DiscoverUITests.swift` run in Xcode. The UI
tests use a DEBUG-only harness (`--discover-ui-test`) with a captured Open Library fixture and an
in-memory store. Backend checks run offline:

```bash
node supabase/tests/discovery-logic.test.mjs
```

```bash
PGLITE_MODULE=/path/to/node_modules/@electric-sql/pglite/dist/index.js TEXTUAL_ROOT="$PWD" node supabase/tests/discovery.test.mjs
```


## Community and friends

Community (the people icon) has two tabs, styled like The Archive's tabs:

- **Friends**: search readers by name or username, accept or decline requests, cancel requests
  you sent, and open a friend's public profile. Friendships are mutual: a request must be
  accepted. A change shows "Sending…" until the server confirms it; nothing appears as a friend
  early.
- **Feed**: friends' reading updates, newest first. It covers starting and finishing books
  (rereads stay separate), saved quotes, shared reviews, and books added to a public shelf. A
  finish, its review, and quotes from the same sitting appear as one card. The feed is view-only:
  no likes, comments, reposts, or posting.

Opening a reader shows the existing public profile page (library card and shelf). On a visitor's
card, **Reads** opens a cover grid of the books they've read, **Rereads** shows their rereads,
and **Genres** shows the Stats genre chart. Lists load 30 books at a time. Covers open the
normal book details; saving or reviewing from there changes your archive only.

**Privacy & sharing** (Menu, or the hint on your Profile) controls:

- **Share my reading activity with friends**. It's on by default for new activity only. Turning
  it off hides what you've already shared. Anything you do while it's off stays private, even if
  you turn sharing back on later. Notes, progress, private reviews, and imported history are
  never shared.
- **Books read, Genres, Rereads** on your library card. A hidden statistic returns no count and
  no list from any endpoint. Hiding Rereads also makes your visible Books read number count
  distinct books. Accounts that existed before this release start with all three hidden (their
  read lists were never public). New profiles start with them visible.

Your shelf always shows the books you chose for it. Reviews have a **Share with friends** switch.
New reviews start shared while activity sharing is on. Existing reviews stay private.

Friend content stays in memory only. It's cleared on sign-out or account switch and refreshed
whenever the app opens or returns to the foreground. If friend content can't be refreshed for an
hour, it's removed from the screen. Content already shown on an offline phone can't be erased
remotely until the app refreshes.

### Apply the social backend

1. In the SQL Editor, apply `supabase/migrations/011_social_graph.sql`, then
   `012_social_activity.sql`. Each runs in one transaction, is additive, and refuses to run
   twice. Current app versions keep working throughout. Both are applied to the existing
   project as of October 13, 2026; don't rerun them there.
2. Then ship this app version. It only sends activity after the database reports
   `activityEnabled` (migration 012), so it also keeps syncing against an unmigrated database.
3. Verify with a second account: send and accept a request, save a quote, and check the
   friend's Feed and Discover → Friends.

Recovery: revoke `execute` on the social read functions to disable social reads without
touching library data. Roll forward with a new migration; don't edit applied ones. Architecture,
permission matrix, and activity rules: [docs/social-architecture.md](docs/social-architecture.md).

### Social tests

The database suite runs in a throwaway local PostgreSQL cluster (`initdb` in a temp directory).
It never connects to Supabase.

```bash
PG_MODULE=/path/to/node_modules/pg/lib/index.js TEXTUAL_ROOT="$PWD" node supabase/tests/social.test.mjs
```

The synthetic load benchmark uses the same disposable setup (`small` or `large`):

```bash
PG_MODULE=/path/to/node_modules/pg/lib/index.js TEXTUAL_ROOT="$PWD" node supabase/tests/social-performance.mjs large
```

`textualTests/SocialTests.swift` covers grouping, intents, sharing stamps, cache isolation, and
the wire contract shared with the database suite (`supabase/tests/fixtures/`).
`textualUITests/CommunityUITests.swift` drives a DEBUG harness (`--community-ui-test`).
