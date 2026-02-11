# Textual: Technical Specification

## Core Architecture
- **Language:** Swift 6 / SwiftUI
- **Storage:** SwiftData (Local-First)
- **Backend:** Supabase (Auth, PostgreSQL, Storage)
- **Image Engine:** Nuke (Caching & Downsampling)

## Data Models
### Book (SwiftData)
- `id`: UUID (Primary Key)
- `isbn`: String (Unique index)
- `title`: String
- `author`: String
- `coverURL`: String
- `googleBooksVolumeId`: String? (optional – Google Books volume ID for detail fetches)
- `tags`: Relationship to [Tag]

## Performance Requirements
- **Local-First:** All UI reads must come from SwiftData `@Query`.
- **Smooth Scrolling:** Use `LazyVStack` and `LazyVGrid` for all lists.
- **Background Sync:** Supabase sync must happen on a background Actor.
