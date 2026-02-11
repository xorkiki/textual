# Textual

A modern, local-first book tracking and social reading app built with Swift 6 and SwiftUI.

## Project Vision

Reading today is fragmented, isolating, and poorly designed. People struggle to meaningfully organize what they want to read, keep track of what they are actually reading, and discover books through taste-aligned signals rather than noisy algorithms. Most existing book apps are cluttered, outdated, and visually uninspiring, making the experience feel utilitarian instead of intimate or culturally relevant.

This app solves that by offering a clean, modern, and aesthetically intentional space for reading life. It provides an elegant system for sorting books, lightweight and useful stats, and social discovery grounded in real reading behavior. Long term, it expands beyond the screen to support modern-day reading salons. Through opt-in, location-based discovery, users can find people nearby reading similar books and form small, intentional groups. The goal is to make reading feel beautiful, social, and alive again, rooted in taste, proximity, and conversation rather than performance or scale.

## Tech Stack

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

## Features

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

## Data Models

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

## Development

### Setup
1. Clone the repository
2. Create `Secrets.xcconfig` with your Supabase credentials:
   ```
   SUPABASE_URL = your_supabase_url
   SUPABASE_ANON_KEY = your_supabase_anon_key
   ```
3. Open `textual.xcodeproj` in Xcode
4. Build and run

### Code Standards
- Follow architectural patterns in `TECHNICAL_SPEC.md`
- Use modern Swift 6 concurrency (async/await)
- Prefer `@Observable` macros for view models
- Always use `Lazy` containers for scrollable content
- Keep view bodies lightweight; move heavy logic to Service classes

## Security

**Important**: Never commit `Secrets.xcconfig` to version control. This file contains your API keys and is automatically excluded via `.gitignore`.

## License

[Add your license here]
