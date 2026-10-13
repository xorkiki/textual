// Pure discovery logic shared by the Edge Function and its Node tests.
// No network, clock, or runtime globals: callers pass every input explicitly.

export type ChartSource = "apple" | "nyt";

/** A verified catalog work ready for textual_apply_discovery_collection. */
export interface DiscoveryBook {
  provider: "openlibrary" | "google";
  provider_id: string; // OL…W work ID, or a Google volume ID when Open Library has no match
  title: string;
  author: string;
  isbns: string[];
  cover_url: string;
  cover_width?: number;
  cover_height?: number;
  first_published_year: number | null;
  published_date: string | null;
  subjects: string[];
  work_key: string;
  popularity: number;
  source_rank?: number;
  sources?: string[];
  expires_at?: string | null;
}

/** One row from a provider chart, before catalog resolution. */
export interface ChartEntry {
  source: ChartSource;
  sourceID: string; // Apple ID or NYT primary ISBN-13
  list: string; // Chart or list name; used only for variety
  rank: number; // 1-based, as published
  listSize: number;
  title: string;
  author: string;
  isbn: string | null;
}

export interface OpenLibraryDoc {
  key?: string;
  title?: string;
  author_name?: string[];
  cover_i?: number;
  first_publish_year?: number;
  subject?: string[];
  language?: string[];
  readinglog_count?: number;
  editions?: { docs?: OpenLibraryEdition[] };
}

export interface OpenLibraryEdition {
  key?: string;
  title?: string;
  cover_i?: number;
  language?: string[];
  isbn?: string[];
  publish_date?: string[];
}

export const OPEN_LIBRARY_FIELDS = [
  "key", "title", "author_name", "cover_i", "first_publish_year", "subject", "language",
  "readinglog_count", "editions", "editions.key", "editions.title", "editions.cover_i",
  "editions.language", "editions.isbn", "editions.publish_date",
].join(",");

/** Explore facets: subjects, eras, and literary origins that shape selection only. */
export interface ExploreFacet {
  id: string;
  query: (year: number) => string;
  minimumReaders: number;
}

export const EXPLORE_FACETS: ExploreFacet[] = [
  { id: "literary", query: () => "subject_key:literary_fiction", minimumReaders: 20 },
  { id: "classics", query: () => "subject_key:classics", minimumReaders: 20 },
  { id: "pre-1900", query: () => "subject_key:fiction first_publish_year:[1500 TO 1899]", minimumReaders: 20 },
  { id: "mid-century", query: () => "subject_key:fiction first_publish_year:[1900 TO 1969]", minimumReaders: 20 },
  { id: "late-century", query: () => "subject_key:fiction first_publish_year:[1970 TO 1999]", minimumReaders: 20 },
  { id: "contemporary", query: (y) => `subject_key:fiction first_publish_year:[2000 TO ${y}]`, minimumReaders: 20 },
  { id: "translated", query: () => "subject_key:translations_into_english", minimumReaders: 15 },
  { id: "japanese", query: () => 'subject:"Japanese fiction"', minimumReaders: 5 },
  { id: "african", query: () => 'subject:"African fiction"', minimumReaders: 5 },
  { id: "latin-american", query: () => 'subject:"Latin American fiction"', minimumReaders: 5 },
  { id: "poetry", query: () => "subject_key:poetry", minimumReaders: 15 },
  { id: "philosophy", query: () => "subject_key:philosophy", minimumReaders: 15 },
  { id: "science", query: () => "subject_key:science", minimumReaders: 15 },
  { id: "history", query: () => "subject_key:history", minimumReaders: 15 },
  { id: "memoir", query: () => "subject_key:autobiography", minimumReaders: 10 },
  { id: "essays", query: () => "subject_key:essays", minimumReaders: 10 },
  { id: "short-stories", query: () => "subject_key:short_stories", minimumReaders: 10 },
  { id: "nature", query: () => "subject_key:nature", minimumReaders: 10 },
  { id: "art", query: () => "subject_key:art", minimumReaders: 10 },
  { id: "psychology", query: () => "subject_key:psychology", minimumReaders: 15 },
  { id: "mystery", query: () => "subject_key:mystery", minimumReaders: 20 },
  { id: "science-fiction", query: () => "subject_key:science_fiction", minimumReaders: 20 },
  { id: "fantasy", query: () => "subject_key:fantasy", minimumReaders: 20 },
  { id: "romance", query: () => "subject_key:romance", minimumReaders: 20 },
  { id: "horror", query: () => "subject_key:horror", minimumReaders: 15 },
  { id: "graphic", query: () => "subject_key:graphic_novels", minimumReaders: 10 },
];

/** New-release queries: one broad pool plus subject pools so one genre can't fill it. */
export const NEW_RELEASE_QUERIES: { id: string; query: string; limit: number }[] = [
  { id: "all", query: "", limit: 100 },
  { id: "memoir", query: "subject_key:biography", limit: 30 },
  { id: "history", query: "subject_key:history", limit: 30 },
  { id: "poetry", query: "subject_key:poetry", limit: 30 },
  { id: "science", query: "subject_key:science", limit: 30 },
  { id: "literary", query: "subject_key:literary_fiction", limit: 30 },
];

// MARK: - Normalization and identity

export function foldText(value: string): string {
  return value.normalize("NFKD").replace(/[̀-ͯ]/g, "").toLowerCase()
    .replace(/[’‘`']/g, "").replace(/&/g, " and ")
    .split(/[^a-z0-9]+/).filter(Boolean).join(" ");
}

/** Main title without series markers or subtitles, for chart-to-catalog matching only. */
export function titleKey(title: string): string {
  const main = title
    .replace(/\s*\([^)]*\)\s*$/g, "")
    .replace(/\s*\[[^\]]*\]\s*$/g, "")
    .split(/:\s| - /)[0];
  return foldText(main).replace(/^(the|a|an) /, "");
}

/** "J.R.R. Tolkien" and "J. R. R. Tolkien" match; different given names do not. */
export function authorKey(author: string): string {
  const words: string[] = [];
  let initials = "";
  for (const token of foldText(author).split(" ").filter(Boolean)) {
    if (token.length === 1) initials += token;
    else {
      if (initials) { words.push(initials); initials = ""; }
      words.push(token);
    }
  }
  if (initials) words.push(initials);
  return words.join(" ");
}

export function splitAuthors(author: string): string[] {
  return author.split(/,| and | & | with /i).map((a) => a.trim()).filter(Boolean);
}

export function normalizedISBN(value: string | null | undefined): string | null {
  const text = (value ?? "").replace(/[-\s]/g, "").toUpperCase();
  if (/^[0-9]{13}$/.test(text)) return text;
  if (/^[0-9]{9}[0-9X]$/.test(text)) return text;
  return null;
}

/** An ISBN-13 embedded in an Apple artwork file name, used only as a search hint. */
export function isbnFromArtwork(url: string | undefined): string | null {
  const match = (url ?? "").match(/\/(97[89][0-9]{10})[^/]*\/[^/]*$/);
  return match ? match[1] : null;
}

/** Same work: equal main titles and at least one equal author identity. */
export function sameWork(chartTitle: string, chartAuthor: string, doc: OpenLibraryDoc): boolean {
  const expected = titleKey(chartTitle);
  if (!expected) return false;
  const titles = [doc.title ?? "", ...(doc.editions?.docs ?? []).map((e) => e.title ?? "")];
  if (!titles.some((t) => t && titleKey(t) === expected)) return false;
  const wanted = new Set(splitAuthors(chartAuthor).map(authorKey).filter(Boolean));
  return (doc.author_name ?? []).some((a) => wanted.has(authorKey(a)));
}

export function workID(doc: OpenLibraryDoc): string | null {
  const id = (doc.key ?? "").split("/").pop() ?? "";
  return /^OL[0-9]{1,20}W$/.test(id) ? id : null;
}

const MONTHS: Record<string, number> = {
  jan: 1, feb: 2, mar: 3, apr: 4, may: 5, jun: 6, jul: 7, aug: 8, sep: 9, oct: 10, nov: 11, dec: 12,
};

/** Only unambiguous full dates become published_date; partial dates stay null. */
export function parsePublishDate(value: string | undefined): string | null {
  if (!value) return null;
  const text = value.trim().toLowerCase();
  let y: number, m: number, d: number;
  let match = text.match(/^(\d{4})-(\d{2})-(\d{2})$/);
  if (match) { [y, m, d] = [Number(match[1]), Number(match[2]), Number(match[3])]; }
  else if ((match = text.match(/^([a-z]{3})[a-z]*\.? (\d{1,2}),? (\d{4})$/))) {
    [y, m, d] = [Number(match[3]), MONTHS[match[1]] ?? 0, Number(match[2])];
  } else if ((match = text.match(/^(\d{1,2}) ([a-z]{3})[a-z]*\.? (\d{4})$/))) {
    [y, m, d] = [Number(match[3]), MONTHS[match[2]] ?? 0, Number(match[1])];
  } else return null;
  const date = new Date(Date.UTC(y, m - 1, d));
  if (!m || date.getUTCMonth() !== m - 1 || date.getUTCDate() !== d) return null;
  return date.toISOString().slice(0, 10);
}

export function coverURL(coverID: number): string {
  return `https://covers.openlibrary.org/b/id/${coverID}-L.jpg`;
}

/**
 * Converts a search document into a discovery book, preferring the matched English
 * edition's title and cover. Records without a work ID, author, or cover are dropped.
 */
export function bookFromDoc(doc: OpenLibraryDoc, minimumReaders = 0): DiscoveryBook | null {
  const id = workID(doc);
  const edition = (doc.editions?.docs ?? [])[0];
  const english = edition?.language?.includes("eng") ?? false;
  const title = ((english ? edition?.title : undefined) ?? doc.title ?? "").trim();
  const author = (doc.author_name ?? [])[0]?.trim() ?? "";
  const cover = (english && edition?.cover_i && edition.cover_i > 0) ? edition.cover_i
    : (doc.cover_i && doc.cover_i > 0 ? doc.cover_i : null);
  const readers = doc.readinglog_count ?? 0;
  if (!id || !title || title.length > 300 || /^untitled\b/i.test(title)) return null;
  if (!author || author.length > 300 || !cover || readers < minimumReaders) return null;
  const isbns = [...new Set((edition?.isbn ?? []).map(normalizedISBN).filter((v): v is string => !!v))]
    .sort((a, b) => b.length - a.length).slice(0, 10);
  const year = doc.first_publish_year;
  return {
    provider: "openlibrary",
    provider_id: id,
    title,
    author,
    isbns,
    cover_url: coverURL(cover),
    first_published_year: typeof year === "number" && year > -3000 && year <= 2100 ? year : null,
    published_date: parsePublishDate(edition?.publish_date?.[0]),
    subjects: (doc.subject ?? []).map((s) => s.trim()).filter((s) => s && s.length <= 120).slice(0, 30),
    work_key: `openlibrary:${id}`,
    popularity: readers,
  };
}

export interface GoogleVolume {
  id?: string;
  volumeInfo?: {
    title?: string;
    authors?: string[];
    publishedDate?: string;
    language?: string;
    categories?: string[];
    industryIdentifiers?: { type?: string; identifier?: string }[];
    imageLinks?: { thumbnail?: string; smallThumbnail?: string };
  };
}

/** Google's front-cover endpoint, without the page-curl effect, at a larger size. */
export function googleCoverURL(thumbnail: string | undefined, width = 800): string | null {
  if (!thumbnail) return null;
  try {
    const url = new URL(thumbnail.replace(/^http:/, "https:"));
    if (!["books.google.com", "books.googleusercontent.com"].includes(url.hostname)) return null;
    url.searchParams.delete("edge");
    url.searchParams.set("fife", `w${width}`);
    return url.toString();
  } catch { return null; }
}

/** Fallback identity for chart books Open Library has not catalogued yet. */
export function bookFromGoogleVolume(volume: GoogleVolume, chartTitle: string, chartAuthor: string): DiscoveryBook | null {
  const id = volume.id ?? "";
  const info = volume.volumeInfo;
  if (!/^[A-Za-z0-9_-]{1,128}$/.test(id) || !info?.title) return null;
  if (titleKey(info.title) !== titleKey(chartTitle)) return null;
  const wanted = new Set(splitAuthors(chartAuthor).map(authorKey).filter(Boolean));
  const author = (info.authors ?? []).find((a) => wanted.has(authorKey(a)));
  const cover = googleCoverURL(info.imageLinks?.thumbnail ?? info.imageLinks?.smallThumbnail);
  if (!author || !cover || info.title.length > 300) return null;
  const isbns = (info.industryIdentifiers ?? []).map((i) => normalizedISBN(i.identifier))
    .filter((v): v is string => !!v).sort((a, b) => b.length - a.length).slice(0, 10);
  const date = info.publishedDate ?? "";
  const year = /^\d{4}/.test(date) ? Number(date.slice(0, 4)) : null;
  return {
    provider: "google",
    provider_id: id,
    title: info.title.trim(),
    author: (info.authors ?? [author]).join(", ").slice(0, 300),
    isbns,
    cover_url: cover,
    first_published_year: year,
    published_date: /^\d{4}-\d{2}-\d{2}$/.test(date) ? date : null,
    subjects: (info.categories ?? []).slice(0, 30),
    work_key: `google:${id}`,
    popularity: 0,
  };
}

/** Removes repeated works, keeping the earliest (best-ranked) occurrence. */
export function uniqueWorks(books: DiscoveryBook[]): DiscoveryBook[] {
  const seen = new Set<string>();
  const byTitle = new Set<string>();
  return books.filter((book) => {
    // Open Library sometimes holds duplicate work records for one book; an exact
    // main-title and author identity match is treated as the same work here.
    const exact = `${titleKey(book.title)}|${authorKey(book.author)}`;
    if (seen.has(book.work_key) || byTitle.has(exact)) return false;
    seen.add(book.work_key);
    byTitle.add(exact);
    return true;
  });
}

/** Recent releases: real first-publication years, no future or undated-stale records. */
export function isRecentRelease(book: DiscoveryBook, now: Date, months = 18): boolean {
  const year = book.first_published_year;
  if (year === null) return false;
  const cutoff = new Date(Date.UTC(now.getUTCFullYear(), now.getUTCMonth() - months, now.getUTCDate()));
  if (year < cutoff.getUTCFullYear() || year > now.getUTCFullYear()) return false;
  if (book.published_date) {
    const date = new Date(`${book.published_date}T00:00:00Z`);
    const soon = new Date(now.getTime() + 14 * 86_400_000);
    if (date < cutoff || date > soon) return false;
  }
  return true;
}

/** Round-robin across facet pools so the result starts varied and stays varied. */
export function interleave<T>(pools: T[][], limit: number): T[] {
  const result: T[] = [];
  const indexes = pools.map(() => 0);
  while (result.length < limit) {
    let added = false;
    for (let p = 0; p < pools.length && result.length < limit; p++) {
      if (indexes[p] < pools[p].length) { result.push(pools[p][indexes[p]++]); added = true; }
    }
    if (!added) break;
  }
  return result;
}

// MARK: - Trending

export interface TrendingInput {
  book: DiscoveryBook;
  entries: ChartEntry[];
}

export interface TrendingResult {
  book: DiscoveryBook;
  score: number;
  sources: ChartSource[];
  list: string;
}

/**
 * Each source family (Apple, NYT) contributes at most one normalized score in (0, 1],
 * from its best list position: 1 − (rank − 1) / listSize. A provider with more lists
 * or longer charts cannot outweigh another, and books on both rise naturally.
 * This is Textual's ordering only, never presented as any provider's ranking.
 */
export function rankTrending(inputs: TrendingInput[]): TrendingResult[] {
  const scored = inputs.map(({ book, entries }) => {
    const best = new Map<ChartSource, { score: number; list: string }>();
    for (const entry of entries) {
      if (entry.rank < 1 || entry.listSize < 1) continue;
      const score = 1 - (Math.min(entry.rank, entry.listSize) - 1) / entry.listSize;
      const current = best.get(entry.source);
      if (!current || score > current.score) best.set(entry.source, { score, list: entry.list });
    }
    const values = [...best.values()];
    const top = values.sort((a, b) => b.score - a.score)[0];
    return {
      book,
      score: values.reduce((sum, v) => sum + v.score, 0),
      sources: [...best.keys()].sort(),
      list: top?.list ?? "",
    };
  }).filter((r) => r.score > 0)
    .sort((a, b) => b.score - a.score || a.book.work_key.localeCompare(b.book.work_key));

  // Variety: avoid three consecutive picks from one list when a close alternative exists.
  const result: TrendingResult[] = [];
  const remaining = [...scored];
  while (remaining.length) {
    const recent = result.slice(-2).map((r) => r.list);
    const repeat = recent.length === 2 && recent[0] === recent[1];
    let index = 0;
    if (repeat && remaining[0].list === recent[1]) {
      const alt = remaining.findIndex((r) => r.list !== recent[1]);
      if (alt > 0 && remaining[alt].score >= remaining[0].score * 0.75) index = alt;
    }
    result.push(remaining.splice(index, 1)[0]);
  }
  return result;
}

// MARK: - Cover measurement

/** Reads width/height from JPEG SOF or PNG IHDR bytes; null until enough bytes arrive. */
export function imageSize(bytes: Uint8Array): { width: number; height: number } | null {
  if (bytes.length >= 24 && bytes[0] === 0x89 && bytes[1] === 0x50 && bytes[2] === 0x4e && bytes[3] === 0x47) {
    const view = new DataView(bytes.buffer, bytes.byteOffset, bytes.byteLength);
    return { width: view.getUint32(16), height: view.getUint32(20) };
  }
  if (bytes.length < 4 || bytes[0] !== 0xff || bytes[1] !== 0xd8) return null;
  let offset = 2;
  while (offset + 9 < bytes.length) {
    if (bytes[offset] !== 0xff) { offset++; continue; }
    const marker = bytes[offset + 1];
    if (marker === 0xff) { offset++; continue; }
    if (marker === 0xd8 || marker === 0x01 || (marker >= 0xd0 && marker <= 0xd7)) { offset += 2; continue; }
    const length = (bytes[offset + 2] << 8) | bytes[offset + 3];
    if (length < 2) return null;
    const isSOF = marker >= 0xc0 && marker <= 0xcf && ![0xc4, 0xc8, 0xcc].includes(marker);
    if (isSOF) {
      const height = (bytes[offset + 5] << 8) | bytes[offset + 6];
      const width = (bytes[offset + 7] << 8) | bytes[offset + 8];
      return width && height ? { width, height } : null;
    }
    offset += 2 + length;
  }
  return null;
}

/** Real cover proportions only: rejects placeholders, banners, and slivers. */
export function isUsableCover(size: { width: number; height: number } | null): boolean {
  if (!size || size.width < 80 || size.height < 80) return false;
  const ratio = size.height / size.width;
  return ratio >= 0.6 && ratio <= 2.2;
}
