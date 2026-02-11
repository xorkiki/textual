# Textual — High-Level Architecture

This document describes the app’s architecture from the entry point through the main feature areas: **Library**, **Reader**, and **Settings**.

## Architecture Overview

```mermaid
flowchart TB
    subgraph entry["Entry Point"]
        A["@main textualApp"]
    end

    subgraph app["App Shell"]
        B["WindowGroup"]
        C["ContentView"]
    end

    subgraph features["Main Features"]
        subgraph library["Library (implemented)"]
            D["LibraryView"]
            E["AddBookView (sheet)"]
            F["BookDetailView (sheet)"]
        end
        subgraph reader["Reader (planned)"]
            G["Reader / reading flow"]
        end
        subgraph settings["Settings (planned)"]
            H["Settings"]
        end
    end

    subgraph data["Data & Services"]
        I["SwiftData ModelContainer\n(Book, Tag)"]
        J["GoogleBooksService (actor)"]
        K["AddBookViewModel\nBookDetailViewModel"]
    end

    A --> B
    B --> C
    C --> D
    D --> E
    D --> F
    C -.-> G
    C -.-> H

    D --> I
    E --> K
    F --> K
    K --> J
    F --> I
```

## Flow Description

| Layer | Component | Role |
|-------|-----------|------|
| **Entry** | `textualApp` | `@main` app; creates SwiftData `ModelContainer` (Book, Tag), configures nav bar and fonts, sets root to `ContentView`. |
| **App shell** | `ContentView` | Root view; currently presents **Library** only (no tab bar yet). |
| **Library** | `LibraryView` | Grid of books from `@Query`; “+” opens **Add Book**; tapping a book opens **Book Detail**. |
| **Add Book** | `AddBookView` | Search UI; uses `AddBookViewModel` → `GoogleBooksService`; saves chosen result as `Book` into SwiftData. |
| **Book Detail** | `BookDetailView` | Shows metadata/description; uses `BookDetailViewModel` to fetch volume via `GoogleBooksService`; loading/error/fallback states. |
| **Reader** | *(planned)* | Reading experience and status (Currently Reading, To Be Read, Read, DNF) per TECHNICAL_SPEC. |
| **Settings** | *(planned)* | App preferences and account; gated by Auth (Email/Apple) per spec. |

## Data Flow (Library)

```mermaid
flowchart LR
    subgraph views["Views"]
        V1["LibraryView"]
        V2["AddBookView"]
        V3["BookDetailView"]
    end
    subgraph vms["ViewModels"]
        VM1["AddBookViewModel"]
        VM2["BookDetailViewModel"]
    end
    subgraph services["Services"]
        SVC["GoogleBooksService"]
    end
    subgraph storage["Storage"]
        SD["SwiftData\n(Book, Tag)"]
    end

    V1 -->|"@Query"| SD
    V1 --> V2
    V1 --> V3
    V2 --> VM1
    V3 --> VM2
    VM1 --> SVC
    VM2 --> SVC
    V2 -->|insert/save| SD
    V3 -->|read book| SD
```

## File Map (Source: `textual/`)

| Area | Files |
|------|--------|
| Entry | `textualApp.swift` |
| Root | `ContentView.swift` |
| Library | `Views/LibraryView.swift` |
| Add Book | `Views/AddBookView.swift` |
| Book Detail | `Views/BookDetailView.swift` |
| ViewModels | `ViewModels/AddBookViewModel.swift`, `ViewModels/BookDetailViewModel.swift` |
| Services | `Services/GoogleBooksService.swift` |
| Models | `BookModel.swift`, `TagModel.swift` |
| Design | `DesignSystem/*` |

Reader and Settings are specified in TECHNICAL_SPEC.md and will plug into the same app shell (e.g. via tabs or navigation) once implemented.
