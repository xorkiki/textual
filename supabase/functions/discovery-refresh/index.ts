// Supabase Edge Function: refreshes Discover's shared collections from external sources.
// Invoked only by the scheduled job (see supabase/setup_discovery_schedule.sql).
// Deploy with JWT verification off; callers must present the Vault-held token instead.
//
// Sources: Open Library (catalog, new releases, Explore), Apple Books charts (public
// marketing feed), the NYT Books API only when NYT_API_KEY is configured, and Google
// Books for chart books Open Library lacks only when GOOGLE_BOOKS_API_KEY is configured.
// No reader data is read or written here.

import {
  bookFromDoc, bookFromGoogleVolume, type GoogleVolume, type ChartEntry, type DiscoveryBook, EXPLORE_FACETS, imageSize, interleave,
  isbnFromArtwork, isRecentRelease, isUsableCover, NEW_RELEASE_QUERIES, normalizedISBN,
  OPEN_LIBRARY_FIELDS, type OpenLibraryDoc, rankTrending, sameWork, splitAuthors, authorKey,
  uniqueWorks,
} from "./discovery.ts";

declare const EdgeRuntime: { waitUntil(promise: Promise<unknown>): void } | undefined;

const SUPABASE_URL = Deno.env.get("SUPABASE_URL") ?? "";
const SERVICE_KEY = serviceKey();
const NYT_KEY = Deno.env.get("NYT_API_KEY")?.trim() || null;
// Optional server key (not the iOS-restricted app key) for chart books Open Library lacks.
const GOOGLE_KEY = Deno.env.get("GOOGLE_BOOKS_API_KEY")?.trim() || null;
const USER_AGENT = "Textual/1.0 (https://github.com/xorkiki/textual; discovery refresh)";
const JOBS = ["trending", "new_releases", "explore"] as const;
type Job = typeof JOBS[number];

const EXPLORE_FACETS_PER_RUN = 6;
const CHART_LOOKUPS_PER_RUN = 30;
const MISS_RETRY_DAYS = 7;
const NYT_ATTRIBUTION = "Data provided by The New York Times";

Deno.serve(async (request) => {
  if (request.method !== "POST") return new Response(null, { status: 405 });
  if (!SUPABASE_URL || !SERVICE_KEY) return new Response("Not configured", { status: 500 });
  const token = request.headers.get("x-textual-discovery-token") ?? "";
  if (!token || (await rpc("textual_discovery_token_valid", { p_token: token })) !== true) {
    return new Response(null, { status: 401 });
  }
  let body: { jobs?: unknown } = {};
  try { body = await request.json(); } catch { /* Empty body is rejected below. */ }
  const jobs = (Array.isArray(body.jobs) ? body.jobs : []).filter((j): j is Job => JOBS.includes(j));
  if (!jobs.length) return new Response("No jobs", { status: 400 });

  const work = (async () => {
    for (const job of jobs) {
      const started = Date.now();
      try {
        const count = await run(job);
        console.log(JSON.stringify({ job, ok: true, books: count, ms: Date.now() - started }));
      } catch (error) {
        // Provider failures keep the previous collection; the read RPC still serves it.
        console.error(JSON.stringify({ job, ok: false, error: String(error), ms: Date.now() - started }));
      }
    }
  })();
  if (typeof EdgeRuntime !== "undefined") {
    EdgeRuntime.waitUntil(work);
    return Response.json({ accepted: jobs }, { status: 202 });
  }
  await work;
  return Response.json({ completed: jobs });
});

function run(job: Job): Promise<number> {
  switch (job) {
    case "trending": return refreshTrending();
    case "new_releases": return refreshNewReleases();
    case "explore": return refreshExplore();
  }
}

// MARK: - Jobs

async function refreshExplore(): Promise<number> {
  const year = new Date().getUTCFullYear();
  const existing: { id: string; refreshed_at: string }[] =
    await rest("textual_discovery_collections?select=id,refreshed_at&kind=eq.explore");
  const refreshed = new Map(existing.map((c) => [c.id, Date.parse(c.refreshed_at)]));
  const facets = [...EXPLORE_FACETS]
    .sort((a, b) => (refreshed.get(`explore:${a.id}`) ?? 0) - (refreshed.get(`explore:${b.id}`) ?? 0))
    .slice(0, EXPLORE_FACETS_PER_RUN);
  let total = 0;
  const failures: string[] = [];
  for (const facet of facets) {
    // One slow or failing pool must not stop the others; it stays stalest and goes first next run.
    try {
      const docs = await searchOpenLibrary(facet.query(year), 60);
      const books = uniqueWorks(docs.map((d) => bookFromDoc(d, facet.minimumReaders))
        .filter((b): b is DiscoveryBook => b !== null)).slice(0, 40);
      const measured = await withMeasuredCovers(books);
      // A thin provider response never replaces a healthy collection.
      if (measured.length < 8) { failures.push(`${facet.id}: ${measured.length} books`); continue; }
      total += await apply({ id: `explore:${facet.id}`, kind: "explore", source: "openlibrary",
        facet: facet.id, books: measured });
    } catch (error) { failures.push(`${facet.id}: ${error}`); }
  }
  if (failures.length) console.warn(JSON.stringify({ job: "explore", skipped: failures }));
  if (total === 0) throw new Error(`No explore pools refreshed: ${failures.join("; ")}`);
  return total;
}

async function refreshNewReleases(): Promise<number> {
  const now = new Date();
  const year = now.getUTCFullYear();
  const range = `first_publish_year:[${year - 1} TO ${year}]`;
  const pools: DiscoveryBook[][] = [];
  for (const query of NEW_RELEASE_QUERIES) {
    try {
      const docs = await searchOpenLibrary(`${query.query} ${range}`.trim(), query.limit);
      pools.push(docs.map((d) => bookFromDoc(d, 3))
        .filter((b): b is DiscoveryBook => b !== null && isRecentRelease(b, now)));
    } catch (error) {
      console.warn(JSON.stringify({ job: "new_releases", skipped: query.id, error: String(error) }));
    }
  }
  const books = uniqueWorks(interleave(pools, 300)).slice(0, 150);
  const measured = await withMeasuredCovers(books);
  if (measured.length < 20) throw new Error(`Only ${measured.length} new releases passed validation`);
  return apply({ id: "new_releases", kind: "new_releases", source: "openlibrary", books: measured });
}

async function refreshTrending(): Promise<number> {
  const entries: ChartEntry[] = [];
  const failures: string[] = [];
  try { entries.push(...await appleChart("top-paid"), ...await appleChart("top-free")); }
  catch (error) { failures.push(`apple: ${error}`); }
  let nytExpiresAt: string | null = null;
  if (NYT_KEY) {
    try {
      entries.push(...await nytOverview());
      nytExpiresAt = new Date(Date.now() + 24 * 3600_000).toISOString();
    } catch (error) { failures.push(`nyt: ${error}`); }
  }
  if (!entries.length) throw new Error(`No chart data: ${failures.join("; ")}`);

  const resolved = await resolveChartEntries(entries);
  const grouped = new Map<string, { book: DiscoveryBook; entries: ChartEntry[] }>();
  for (const entry of entries) {
    const book = resolved.get(`${entry.source}:${entry.sourceID}`);
    if (!book) continue;
    const group = grouped.get(book.work_key) ?? { book, entries: [] };
    group.entries.push(entry);
    grouped.set(book.work_key, group);
  }
  const ranked = rankTrending([...grouped.values()]);
  const measured = await withMeasuredCovers(ranked.map((r) => r.book));
  const valid = new Set(measured.map((b) => b.work_key));
  const sizes = new Map(measured.map((b) => [b.work_key, b]));
  const books = ranked.filter((r) => valid.has(r.book.work_key)).map((r) => {
    const book = sizes.get(r.book.work_key)!;
    const best = Math.min(...(grouped.get(book.work_key)?.entries ?? []).map((e) => e.rank));
    return {
      ...book,
      source_rank: Number.isFinite(best) ? best : undefined,
      sources: r.sources,
      // NYT terms: their list content may not be cached for more than 24 hours.
      expires_at: r.sources.length === 1 && r.sources[0] === "nyt" ? nytExpiresAt : null,
    };
  });
  // A thin result never replaces an established list; the first fill publishes real matches.
  const existing: { id: string }[] = await rest("textual_discovery_collections?select=id&id=eq.trending");
  if (books.length < (existing.length ? 10 : 1)) {
    throw new Error(`Only ${books.length} trending books resolved; ${failures.join("; ")}`);
  }
  const usesNYT = books.some((b) => b.sources.includes("nyt"));
  return apply({ id: "trending", kind: "trending", source: usesNYT ? "nyt" : "apple",
    attribution: usesNYT ? NYT_ATTRIBUTION : null, books });
}

// MARK: - Chart providers

interface AppleFeed {
  feed?: { results?: { id?: string; name?: string; artistName?: string; artworkUrl100?: string;
    genres?: { name?: string }[] }[] };
}

async function appleChart(kind: "top-paid" | "top-free"): Promise<ChartEntry[]> {
  const url = `https://rss.marketingtools.apple.com/api/v2/us/books/${kind}/50/books.json`;
  const response = await fetchPatiently(url, `Apple ${kind}`);
  const results = ((await response.json()) as AppleFeed).feed?.results ?? [];
  return results.flatMap((r, index) => r.id && r.name && r.artistName ? [{
    source: "apple" as const, sourceID: r.id, list: r.genres?.[0]?.name ?? kind,
    rank: index + 1, listSize: results.length, title: r.name, author: r.artistName,
    isbn: isbnFromArtwork(r.artworkUrl100),
  }] : []);
}

interface NYTOverview {
  results?: { lists?: { list_name?: string; books?: { rank?: number; primary_isbn13?: string;
    primary_isbn10?: string; title?: string; author?: string }[] }[] };
}

async function nytOverview(): Promise<ChartEntry[]> {
  const url = new URL("https://api.nytimes.com/svc/books/v3/lists/overview.json");
  url.searchParams.set("api-key", NYT_KEY!);
  const response = await fetchPatiently(url.toString(), "NYT");
  const lists = ((await response.json()) as NYTOverview).results?.lists ?? [];
  return lists.flatMap((list) => (list.books ?? []).flatMap((book) => {
    const isbn = normalizedISBN(book.primary_isbn13) ?? normalizedISBN(book.primary_isbn10);
    if (!isbn || !book.title || !book.author || !book.rank) return [];
    return [{ source: "nyt" as const, sourceID: isbn, list: list.list_name ?? "nyt", rank: book.rank,
      listSize: list.books?.length ?? 15, title: book.title, author: book.author, isbn }];
  }));
}

/** Resolves chart rows to Open Library works, reusing cached matches and misses. */
async function resolveChartEntries(entries: ChartEntry[]): Promise<Map<string, DiscoveryBook>> {
  const unique = [...new Map(entries.map((e) => [`${e.source}:${e.sourceID}`, e])).values()]
    .sort((a, b) => a.rank / a.listSize - b.rank / b.listSize);
  const cached = new Map<string, { provider: string | null; provider_id: string | null; resolved_at: string }>();
  for (const source of ["apple", "nyt"] as const) {
    const ids = unique.filter((e) => e.source === source).map((e) => e.sourceID);
    for (const chunk of chunks(ids, 80)) {
      const rows: { source_id: string; provider: string | null; provider_id: string | null; resolved_at: string }[] = await rest(
        `textual_discovery_resolutions?select=source_id,provider,provider_id,resolved_at&source=eq.${source}` +
        `&source_id=in.(${chunk.map(encodeURIComponent).join(",")})`);
      for (const row of rows) cached.set(`${source}:${row.source_id}`, row);
    }
  }
  const workKey = (row: { provider: string | null; provider_id: string | null }) =>
    row.provider && row.provider_id ? `${row.provider}:${row.provider_id}` : null;
  const knownWorks = [...new Set([...cached.values()].flatMap((r) => workKey(r) ?? []))];
  const snapshots = await storedBooks(knownWorks);

  const result = new Map<string, DiscoveryBook>();
  let lookups = 0;
  for (const entry of unique) {
    const key = `${entry.source}:${entry.sourceID}`;
    const hit = cached.get(key);
    const known = hit ? workKey(hit) : null;
    if (known && snapshots.has(known)) {
      result.set(key, snapshots.get(known)!);
      continue;
    }
    const recentMiss = hit && !hit.provider_id &&
      Date.now() - Date.parse(hit.resolved_at) < MISS_RETRY_DAYS * 86_400_000;
    if (recentMiss || lookups >= CHART_LOOKUPS_PER_RUN) continue;
    lookups++;
    const book = await lookupChartEntry(entry);
    await rest("textual_discovery_resolutions?on_conflict=source,source_id", {
      method: "POST",
      headers: { Prefer: "resolution=merge-duplicates,return=minimal" },
      body: JSON.stringify([{ source: entry.source, source_id: entry.sourceID,
        provider: book?.provider ?? null, provider_id: book?.provider_id ?? null,
        resolved_at: new Date().toISOString() }]),
    });
    if (book) result.set(key, book);
  }
  return result;
}

async function lookupChartEntry(entry: ChartEntry): Promise<DiscoveryBook | null> {
  if (entry.isbn) {
    const docs = await searchOpenLibrary(`isbn:${entry.isbn}`, 3, null);
    const wanted = new Set(splitAuthors(entry.author).map(authorKey));
    // The ISBN identifies the edition; the author check guards against bad index data.
    const doc = docs.find((d) => (d.author_name ?? []).some((a) => wanted.has(authorKey(a))));
    const book = doc ? bookFromDoc(doc) : null;
    if (book) return book;
  }
  const title = entry.title.replace(/"/g, "");
  const author = splitAuthors(entry.author)[0]?.replace(/"/g, "") ?? "";
  if (!title || !author) return null;
  const docs = await searchOpenLibrary(`title:"${title}" author:"${author}"`, 5);
  const doc = docs.find((d) => sameWork(entry.title, entry.author, d));
  const book = doc ? bookFromDoc(doc) : null;
  return book ?? (GOOGLE_KEY ? await lookupGoogle(entry, title, author) : null);
}

async function lookupGoogle(entry: ChartEntry, title: string, author: string): Promise<DiscoveryBook | null> {
  const url = new URL("https://www.googleapis.com/books/v1/volumes");
  url.searchParams.set("q", entry.isbn ? `isbn:${entry.isbn}` : `intitle:"${title}" inauthor:"${author}"`);
  url.searchParams.set("maxResults", "5");
  url.searchParams.set("printType", "books");
  url.searchParams.set("key", GOOGLE_KEY!);
  try {
    const response = await fetchWithTimeout(url.toString(), { headers: { "User-Agent": USER_AGENT } });
    if (!response.ok) return null;
    const items = ((await response.json()) as { items?: GoogleVolume[] }).items ?? [];
    for (const item of items) {
      const book = bookFromGoogleVolume(item, entry.title, entry.author);
      if (book) return book;
    }
  } catch { /* A Google miss leaves the chart row unresolved; nothing is invented. */ }
  return null;
}

// MARK: - Open Library

let lastOpenLibraryRequest = 0;

/** Sequential and at most about one request per second, per Open Library's guidance.
 *  A timeout, rate limit, or server error is retried once after a pause, more patiently. */
async function searchOpenLibrary(query: string, limit: number,
                                 sort: string | null = "readinglog"): Promise<OpenLibraryDoc[]> {
  try {
    return await searchOpenLibraryOnce(query, limit, sort, 25_000);
  } catch (error) {
    const status = Number(String(error).match(/Open Library (\d+)/)?.[1] ?? 0);
    const retryable = (error as Error)?.name === "AbortError" || status === 429 || status >= 500;
    if (!retryable) throw error;
    await new Promise((resolve) => setTimeout(resolve, 3000));
    return await searchOpenLibraryOnce(query, limit, sort, 45_000);
  }
}

async function searchOpenLibraryOnce(query: string, limit: number, sort: string | null,
                                     timeout: number): Promise<OpenLibraryDoc[]> {
  const wait = lastOpenLibraryRequest + 1100 - Date.now();
  if (wait > 0) await new Promise((resolve) => setTimeout(resolve, wait));
  lastOpenLibraryRequest = Date.now();
  const url = new URL("https://openlibrary.org/search.json");
  url.searchParams.set("q", `${query} language:eng`.trim());
  url.searchParams.set("limit", String(limit));
  url.searchParams.set("lang", "en");
  url.searchParams.set("fields", OPEN_LIBRARY_FIELDS);
  if (sort) url.searchParams.set("sort", sort);
  const response = await fetchWithTimeout(url.toString(), {
    headers: { "User-Agent": USER_AGENT, Accept: "application/json" } }, timeout);
  if (!response.ok) throw new Error(`Open Library ${response.status}`);
  return ((await response.json()) as { docs?: OpenLibraryDoc[] }).docs ?? [];
}

/** Adds measured cover sizes, reusing stored measurements; drops unusable covers. */
async function withMeasuredCovers(books: DiscoveryBook[]): Promise<DiscoveryBook[]> {
  const stored = await storedBooks(books.map((b) => b.work_key));
  const measured = await mapLimit(books, 6, async (book) => {
    const known = stored.get(book.work_key);
    if (known && known.cover_url === book.cover_url && known.cover_width && known.cover_height) {
      return { ...book, cover_width: known.cover_width, cover_height: known.cover_height };
    }
    const size = await measureCover(book.cover_url);
    return isUsableCover(size) ? { ...book, cover_width: size!.width, cover_height: size!.height } : null;
  });
  return measured.filter((b): b is DiscoveryBook => b !== null);
}

async function measureCover(url: string): Promise<{ width: number; height: number } | null> {
  try {
    // default=false turns a missing cover into an error instead of a blank image.
    const response = await fetchWithTimeout(`${url}?default=false`, { headers: { "User-Agent": USER_AGENT } }, 15_000);
    if (!response.ok || !response.body) return null;
    const reader = response.body.getReader();
    let buffer = new Uint8Array(0);
    while (buffer.length < 512 * 1024) {
      const { done, value } = await reader.read();
      if (done) break;
      const next = new Uint8Array(buffer.length + value.length);
      next.set(buffer); next.set(value, buffer.length);
      buffer = next;
      const size = imageSize(buffer);
      if (size) { await reader.cancel(); return buffer.length >= 1024 || size.width >= 80 ? size : null; }
    }
    await reader.cancel();
    return imageSize(buffer);
  } catch { return null; }
}

// MARK: - Supabase

async function storedBooks(workKeys: string[]): Promise<Map<string, DiscoveryBook>> {
  const result = new Map<string, DiscoveryBook>();
  for (const chunk of chunks([...new Set(workKeys)], 60)) {
    const rows: Omit<DiscoveryBook, "provider" | "provider_id">[] =
      await rest("textual_discovery_books?select=title,author,isbns,cover_url,cover_width,cover_height," +
        "first_published_year,published_date,subjects,work_key,popularity" +
        `&work_key=in.(${chunk.map((k) => `"${k}"`).map(encodeURIComponent).join(",")})`);
    for (const row of rows) {
      // work_key is "<provider>:<provider ID>", written by this function.
      const [provider, ...idParts] = row.work_key.split(":");
      if (provider !== "openlibrary" && provider !== "google") continue;
      result.set(row.work_key, { ...row, provider, provider_id: idParts.join(":") });
    }
  }
  return result;
}

function apply(collection: { id: string; kind: string; source: string; facet?: string;
  attribution?: string | null; books: DiscoveryBook[] }): Promise<number> {
  return rpc("textual_apply_discovery_collection", { p_collection: collection }) as Promise<number>;
}

function authHeaders(): Record<string, string> {
  // New secret keys go in apikey only; legacy service-role JWTs also use Authorization.
  return SERVICE_KEY.startsWith("sb_secret_") ? { apikey: SERVICE_KEY }
    : { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` };
}

async function rest(path: string, init: RequestInit = {}): Promise<any> {
  const response = await fetchWithTimeout(`${SUPABASE_URL}/rest/v1/${path}`, {
    ...init,
    headers: { ...authHeaders(), "Content-Type": "application/json", ...(init.headers ?? {}) },
  }, 30_000);
  if (!response.ok) throw new Error(`Database ${response.status}: ${(await response.text()).slice(0, 300)}`);
  const text = await response.text();
  return text ? JSON.parse(text) : null;
}

function rpc(name: string, params: unknown): Promise<unknown> {
  return rest(`rpc/${name}`, { method: "POST", body: JSON.stringify(params) });
}

// MARK: - Utilities

/** Supabase injects either a legacy service-role JWT or the newer secret API keys. */
function serviceKey(): string {
  const legacy = Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")?.trim();
  if (legacy) return legacy;
  const single = Deno.env.get("SUPABASE_SECRET_KEY")?.trim();
  if (single) return single;
  try {
    const keys = JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS") ?? "{}") as Record<string, string>;
    return keys.default ?? Object.values(keys)[0] ?? "";
  } catch { return ""; }
}

/** One retry after a pause for timeouts, rate limits, and server errors; then it fails. */
async function fetchPatiently(url: string, label: string): Promise<Response> {
  for (const [attempt, timeout] of [[1, 20_000], [2, 45_000]] as const) {
    try {
      const response = await fetchWithTimeout(url, { headers: { "User-Agent": USER_AGENT } }, timeout);
      if (response.ok) return response;
      if (attempt === 2 || !(response.status === 429 || response.status >= 500)) {
        throw new Error(`${label} ${response.status}`);
      }
    } catch (error) {
      if (attempt === 2 || (error as Error)?.name !== "AbortError") throw error;
    }
    await new Promise((resolve) => setTimeout(resolve, 3000));
  }
  throw new Error(`${label} unavailable`);
}

async function fetchWithTimeout(url: string, init: RequestInit = {}, ms = 20_000): Promise<Response> {
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), ms);
  try { return await fetch(url, { ...init, signal: controller.signal, redirect: "follow" }); }
  finally { clearTimeout(timer); }
}

async function mapLimit<T, R>(items: T[], limit: number, transform: (item: T) => Promise<R>): Promise<R[]> {
  const results = new Array<R>(items.length);
  let next = 0;
  await Promise.all(Array.from({ length: Math.min(limit, items.length) }, async () => {
    while (next < items.length) {
      const index = next++;
      results[index] = await transform(items[index]);
    }
  }));
  return results;
}

function chunks<T>(items: T[], size: number): T[][] {
  const result: T[][] = [];
  for (let i = 0; i < items.length; i += size) result.push(items.slice(i, i + size));
  return result;
}
