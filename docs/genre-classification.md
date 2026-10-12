# Shared genre classification

`GenreTaxonomy.swift` is Textual’s versioned, app-wide category map. It applies to every account. Archive, Stats, and reader profiles all read through `StatsMetadataCache.genres`. That lookup prefers newer classification evidence and falls back to saved catalog metadata when new evidence is missing, unreadable, or too generic. It never changes imported reading data or edition details.

## Matching policy

- Use catalog subject/category metadata only, not book titles, author identities, private user tags, or guesses from a reader’s profile.
- Normalize case, accents, apostrophes, punctuation, and hyphens. Compare whole words and phrases instead of arbitrary substrings.
- Treat each slash-delimited catalog segment separately. Recognize synonyms and narrower subjects under broad categories.
- Assign multiple categories when supported: a lesbian romance belongs to both LGBTQIA+ and Romance; romantasy belongs to both Romance and Fantasy.
- Keep contextual exceptions for misleading terms: science fiction is not automatically Science, political science maps to Politics, true crime does not imply fictional Crime, and biological reproduction does not imply an LGBTQIA+ theme.
- Distinguish children’s/juvenile categories from an explicit middle-grade age category.
- Preserve an unfamiliar publisher category when no known category matches. Unrecognized Open Library subjects do not become genres because they can be people, places, or incidental topics. Missing evidence remains unclassified.
- Archive’s status, genre, mood, and pace filters still combine. A genre available in the whole library may have no books in the selected reading status.

## Examples

| Catalog wording | Shared filter categories |
| --- | --- |
| Gay fiction; bisexual; transgender; nonbinary; sapphic | LGBTQIA+ |
| Lesbian romance | LGBTQIA+, Romance |
| Young adult fiction / LGBTQ+ / Bisexual | Young adult, LGBTQIA+ |
| Romantasy | Fantasy, Romance |
| Cyberpunk; space opera; sci-fi | Science fiction |
| Psychological thrillers | Thriller |
| Cozy mysteries | Mystery |
| Cookery; recipes | Cooking |
| Personal development; self-improvement | Self help |
| Manga; comic books | Graphic novels |
| Humour; satire | Humor |
| Juvenile fiction | Children’s |

The complete aliases and exclusions are the `Rule` entries in `GenreTaxonomy.swift`. Change them centrally, add positive and negative regression examples, and increment `version` when the mapping changes. The vocabulary is recomputed from raw saved metadata when a page reads it, so existing books benefit immediately on an updated app; no account-specific migration, reimport, or server database is needed. Distribution to users requires shipping the updated app.

## Standards and limits

This is an original, product-specific controlled vocabulary, informed by hierarchical subject classification and synonym matching. It is not a complete licensed BISAC database or a claim of official BISAC compliance. References: [BISG’s fiction subject guidance](https://www.bisg.org/fiction), [Library of Congress controlled vocabularies](https://www.loc.gov/librarians/controlled-vocabularies/), and [LC’s distinction between genre/form and subjects](https://www.loc.gov/catdir/cpso/genreformgeneral.html).

The UI’s Genre filter includes genres, forms, audiences, and themes for browsing. Metadata coverage still limits results: a book with no relevant subject label cannot safely be assigned that category. Source priority is retained rather than merging stale, conflicting catalog data into newer classifications.
