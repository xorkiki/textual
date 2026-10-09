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
- **Follow System**: Users must follow others to see their activity feed
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

StoryGraph CSV imports preserve and sync private reading statuses, dates, ratings, reviews, and export metadata. Editing those fields, custom shelves, follows/activity feeds, Apple Sign-In, and the Reader remain planned. Imported tags are preserved as metadata; custom shelf membership is not yet synced.

## Navigation and next pages

After signing in and completing a profile, the app opens **The Archive**. Its bottom navigation is an icon-only capsule with a wider oval highlight for the selected tab (#4C1308 at 30%). Its charcoal fill (#232323 at 35%) matches the dark login button, without an outline, with #8C8C8C icons in this order: Home, My Archive, The Archive, Stats, Menu. My Archive retains the book grid, add/search sheet, details, and sync controls. Existing account settings and device-library import are available through Menu → Account. Home, The Archive, and Stats are placeholders; their features are deliberately deferred.

Book cards align at the top of each row and reserve two lines for titles so covers and author labels line up. Books scroll behind the compact header and bottom menu, fading beneath those controls. Content padding keeps the first and last rows readable at rest without the extra large-title gap. Library and search scroll indicators are hidden. Search begins at three characters, matching the catalog's minimum, with an inline hint for shorter input.

Page direction saved from Kiki’s October 8, 2026 request (future work):

| Page | Planned purpose |
|---|---|
| Home | Profile, current read, and an up-next pile |
| My Archive | Saved books and custom categories |
| The Archive | What friends are reading and suggested reads |
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
