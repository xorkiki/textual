// SYNTHETIC LOCAL LOAD — disposable PostgreSQL only (support/local-postgres.mjs).
// Generates fake readers, libraries, friendships, and activity in a throwaway
// cluster, then reports per-RPC latency under the real `authenticated` role and the
// nested query plans (auto_explain: ANALYZE + BUFFERS) of the social functions.
// Never run against Supabase or any shared database; numbers are a local laptop
// measurement, not a production capacity claim.
//
// Run: PG_MODULE=/path/to/node_modules/pg/lib/index.js TEXTUAL_ROOT="$PWD" node supabase/tests/social-performance.mjs [small|large]
import { startCluster, applyMigrations, BASE_MIGRATIONS, SOCIAL_MIGRATIONS, as, asAdmin, uid } from './support/local-postgres.mjs';

const SIZES = {
    small: { readers: 60, books: 40, friends: 8, events: 6 },
    large: { readers: 3000, books: 300, friends: 150, events: 120 }
};
const size = SIZES[process.argv[2] ?? 'large'] ?? SIZES.large;
const showPlans = process.env.SHOW_PLANS === '1';

const cluster = await startCluster();
try {
    const db = await cluster.createDatabase('perf');
    await applyMigrations(db, [...BASE_MIGRATIONS, ...SOCIAL_MIGRATIONS]);
    const started = Date.now();
    const { readers, books, friends, events } = size;
    // Readers, profiles (mixed visibility), and published cards with 15-book shelves.
    await db.query(`insert into auth.users(id) select ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid from generate_series(1, $1) n`, [readers]);
    await db.query(`insert into public.textual_profiles(user_id, first_name, username, books_read_visible, rereads_visible)
        select ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid,
               (array['Ada','Bea','Cleo','Dot','Eli','Fern','Gus','Hal','Ivy','Jo'])[1 + n % 10] || n,
               (array['ada','bea','cleo','dot','eli','fern','gus','hal','ivy','jo'])[1 + n % 10] || '_' || n,
               n % 5 <> 0, n % 3 <> 0
          from generate_series(1, $1) n`, [readers]);
    // A shared catalog of 5,000 works.
    await db.query(`insert into public.textual_books(provider, provider_id) select 'openlibrary', 'OL' || n || 'W' from generate_series(1, 5000) n`);
    // Each reader's library: mostly completed reads, some rereads, some unread.
    await db.query(`insert into public.textual_library_entries(user_id, id, book_id, title, author, revision, updated_at, reading_data)
        select u.id, gen_random_uuid(), b.id, 'Title ' || b.provider_id, 'Writer', row_number() over (partition by u.id order by b.id), now(),
               jsonb_build_object('version', 1, 'sourceKey', repeat('a', 64),
                   'status', case when (hashtext(u.id::text || b.id::text) & 7) = 0 then 'to-read' else 'read' end,
                   'readCount', case when (hashtext(b.id::text || u.id::text) & 15) = 0 then 2 else 1 end,
                   'periods', jsonb_build_array(jsonb_build_object('startedOn', '2025-01-01', 'finishedOn', '2025-02-01')),
                   'format', '', 'moods', '[]'::jsonb, 'pace', '', 'tags', '[]'::jsonb, 'originalFields', '{}'::jsonb,
                   'journal', jsonb_build_object('quotes', jsonb_build_array(jsonb_build_object('id', gen_random_uuid(), 'text', 'A line', 'createdAt', 0)), 'notes', '[]'::jsonb))
          from auth.users u
          cross join lateral (select id, provider_id from public.textual_books order by hashtext(u.id::text || id::text) limit $1) b`, [books]);
    await db.query(`insert into public.textual_sync_state(user_id, last_revision) select id, $1 from auth.users`, [books]);
    await db.query(`insert into public.textual_reader_profiles(user_id, content)
        select p.user_id, jsonb_build_object('stats', jsonb_build_object('reads', 1, 'genres', 1, 'rereads', 0), 'sentence', 'hello',
               'favorites', (select jsonb_agg(jsonb_build_object('id', gen_random_uuid(), 'title', 'Fav', 'author', 'Writer', 'isbn', '',
                   'coverURL', '', 'catalogID', 'openlibrary:' || b.provider_id))
                   from (select provider_id from public.textual_books order by hashtext(p.user_id::text || provider_id) limit 15) b),
               'genreBreakdown', jsonb_build_array(jsonb_build_object('name', 'Fantasy', 'books', 10, 'reads', 12)))
          from public.textual_profiles p`);
    // Accepted friendships: each reader befriends the next N readers (ring), plus pending requests.
    await db.query(`insert into public.textual_friendships(user_low, user_high, status, requester_id, request_id, version, requested_at, accepted_at)
        select least(a, b), greatest(a, b), 'accepted', a, gen_random_uuid(), 2, now(), now()
          from (select ('00000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid a,
                       ('00000000-0000-0000-0000-' || lpad((1 + (n + k - 1) % $1)::text, 12, '0'))::uuid b
                  from generate_series(1, $1) n, generate_series(1, $2) k) pairs
         where a <> b on conflict do nothing`, [readers, Math.max(1, friends / 2)]);
    // Activity: started/finished/quote events per reader, spread over 120 days, mostly eligible.
    await db.query(`insert into public.textual_activity(actor_id, transition_id, kind, book_id, entry_id, quote_id, read_number, eligible, occurred_at, published_at)
        select e.user_id, gen_random_uuid(), k.kind, e.book_id, e.id,
               case when k.kind = 'quote' then ((e.reading_data->'journal'->'quotes'->0->>'id'))::uuid end,
               case when k.kind <> 'quote' then 1 end,
               (hashtext(e.id::text) & 7) <> 0, ts, ts
          from (select e.*, row_number() over (partition by e.user_id order by e.id) rn from public.textual_library_entries e) e
          cross join lateral (select now() - (random() * interval '120 days') ts) t
          cross join (values ('started'), ('finished'), ('quote')) k(kind)
         where e.rn <= $1 / 3
        on conflict do nothing`, [events]);
    await db.query('analyze');
    const counts = (await db.query(`select (select count(*) from auth.users) readers,
        (select count(*) from public.textual_library_entries) entries,
        (select count(*) from public.textual_friendships where status = 'accepted') friendships,
        (select count(*) from public.textual_activity) activity`)).rows[0];
    console.log(`SYNTHETIC ${process.argv[2] ?? 'large'} dataset (generated in ${((Date.now() - started) / 1000).toFixed(1)} s):`, counts);

    const viewer = uid(1);
    const target = (await db.query('select username from public.textual_profiles where user_id = $1', [uid(2)])).rows[0].username;
    const one = async (sql, params) => (await db.query(sql, params)).rows[0]?.r;
    await as(db, viewer);
    const feedFirst = await one('select public.textual_read_feed() r');
    const deep = { ...feedFirst };
    for (let i = 0; i < 4 && deep.next; i++) Object.assign(deep, await one('select public.textual_read_feed($1, $2, $3) r', [feedFirst.cutoff, deep.next.published_at, deep.next.id]));
    const booksFirst = await one('select public.textual_read_profile_books($1, $2) r', [target, 'read']);
    const discoveryFirst = await one('select public.textual_read_friend_discovery() r');

    const cases = [
        ['feed: first page (25)', 'select public.textual_read_feed() r', []],
        ['feed: page 5 (keyset)', 'select public.textual_read_feed($1, $2, $3) r', [feedFirst.cutoff, deep.next?.published_at ?? null, deep.next?.id ?? null]],
        ['public profile + card counts', 'select public.textual_read_public_profile($1) r', [target]],
        ['books read: first page (30)', 'select public.textual_read_profile_books($1, $2) r', [target, 'read']],
        ['books read: next page', 'select public.textual_read_profile_books($1, $2, $3, $4) r', [target, 'read', booksFirst.next?.title ?? null, booksFirst.next?.id ?? null]],
        ['rereads: first page', 'select public.textual_read_profile_books($1, $2) r', [target, 'rereads']],
        ['search: "jo" (2 chars)', 'select public.textual_search_readers($1) r', ['jo']],
        ['search: "ivy_12"', 'select public.textual_search_readers($1) r', ['ivy_12']],
        ['friends list', 'select public.textual_list_friends() r', []],
        ['discover friends: first page (24)', 'select public.textual_read_friend_discovery() r', []],
        ['discover friends: next page', 'select public.textual_read_friend_discovery($1, $2, $3) r', [discoveryFirst.snapshot, discoveryFirst.next?.score ?? null, discoveryFirst.next?.book_id ?? null]]
    ];
    console.log('\nLatency per call (ms), authenticated role, warm cache, 15 runs each:');
    for (const [name, sql, params] of cases) {
        const times = [];
        for (let i = 0; i < 15; i++) {
            const t0 = process.hrtime.bigint();
            await db.query(sql, params);
            times.push(Number(process.hrtime.bigint() - t0) / 1e6);
            // The search limiter is a real server limit; keep the benchmark under it.
            if (sql.includes('search')) { await asAdmin(db); await db.query('delete from public.textual_social_rate_limits'); await as(db, viewer); }
        }
        times.sort((a, b) => a - b);
        console.log(`  ${name.padEnd(36)} median ${times[7].toFixed(2).padStart(7)}  p95 ${times[14].toFixed(2).padStart(7)}`);
    }

    // Library sync with activity intents: the write path that now records activity.
    const writer = uid(3);
    await asAdmin(db);
    const entry = (await db.query('select id, book_id, revision, reading_data from public.textual_library_entries where user_id = $1 limit 1', [writer])).rows[0];
    const version = (await db.query('select sharing_version from public.textual_profiles where user_id = $1', [writer])).rows[0].sharing_version;
    const book = (await db.query('select provider, provider_id from public.textual_books where id = $1', [entry.book_id])).rows[0];
    await as(db, writer);
    const syncTimes = [];
    let revision = Number(entry.revision);
    for (let i = 0; i < 15; i++) {
        const quoteID = crypto.randomUUID();
        const reading = { ...entry.reading_data, journal: { quotes: [...entry.reading_data.journal.quotes, { id: quoteID, text: 'New', createdAt: 0 }], notes: [] } };
        entry.reading_data = reading;
        const change = { operation_id: crypto.randomUUID(), entry_id: entry.id, expected_revision: revision, deleted: false,
            book: { provider: book.provider, provider_id: book.provider_id, title: 'Title', author: 'Writer' }, reading_data: reading,
            activity: [{ id: crypto.randomUUID(), kind: 'quote', shared: true, sharing_version: Number(version), occurred_at: new Date().toISOString(), quote_id: quoteID }] };
        const t0 = process.hrtime.bigint();
        const result = await one('select public.textual_sync_library($1, $2::jsonb, $3, 1) r', [writer, JSON.stringify([change]), 0]);
        syncTimes.push(Number(process.hrtime.bigint() - t0) / 1e6);
        revision = result.results[0].entry.revision;
    }
    syncTimes.sort((a, b) => a - b);
    console.log(`  ${'library sync + verified quote intent'.padEnd(36)} median ${syncTimes[7].toFixed(2).padStart(7)}  p95 ${syncTimes[14].toFixed(2).padStart(7)}`);

    if (showPlans) {
        // Nested plans of the definer functions' own statements.
        await asAdmin(db);
        await db.query(`load 'auto_explain'`);
        await db.query(`set auto_explain.log_min_duration = 0; set auto_explain.log_analyze = on; set auto_explain.log_buffers = on;
                        set auto_explain.log_nested_statements = on; set auto_explain.log_level = notice; set auto_explain.log_format = text`);
        const plans = [];
        db.on('notice', notice => plans.push(notice.message));
        await as(db, viewer);
        for (const [name, sql, params] of [cases[0], cases[1], cases[2], cases[3], cases[6], cases[9]]) {
            plans.length = 0;
            await db.query(sql, params);
            console.log(`\n=== ${name} ===`);
            for (const plan of plans) {
                const lines = plan.split('\n');
                if (lines.some(line => /textual_(activity|friendships|library_entries|profiles|reader_profiles)/.test(line))) {
                    console.log(lines.filter(line => /(Scan|Join|Loop|Sort|Limit|Execution Time|Buffers: shared|actual time=.*rows=)/.test(line)).slice(0, 40).join('\n'));
                }
            }
        }
    }
    await db.end();
} finally {
    await cluster.stop();
}
