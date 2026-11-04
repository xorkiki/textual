// Social system database tests. Disposable local PostgreSQL only (see
// support/local-postgres.mjs); never connects to Supabase or real accounts.
// Every assertion about access runs through the real `authenticated` or `anon`
// role with a JWT subject, so RLS, grants, and auth.uid() behave as in PostgREST.
//
// Run: PG_MODULE=/path/to/node_modules/pg/lib/index.js TEXTUAL_ROOT="$PWD" node supabase/tests/social.test.mjs
import assert from 'node:assert/strict';
import { readFile, writeFile } from 'node:fs/promises';
import { randomUUID } from 'node:crypto';
import { startCluster, applyMigrations, BASE_MIGRATIONS, SOCIAL_MIGRATIONS, as, asAdmin, uid, root } from './support/local-postgres.mjs';

let checks = 0;
const ok = (value, message) => { assert.ok(value, message); checks++; };
const eq = (actual, expected, message) => { assert.deepEqual(actual, expected, message); checks++; };
async function rejects(action, code, message) {
    await assert.rejects(action, error => (code ? error.code === code : true) || assert.fail(`${message}: got ${error.code} ${error.message}`), message);
    checks++;
}

const statsFixture = JSON.parse(await readFile(`${root}/supabase/tests/fixtures/reading-stats.json`, 'utf8'));
const contractPath = `${root}/supabase/tests/fixtures/social-contract.json`;
const contract = JSON.parse(await readFile(contractPath, 'utf8'));
const captured = {};
// Types only: IDs and timestamps differ per run, structure must not.
const shape = value => value === null ? 'null' : Array.isArray(value) ? (value.length ? [shape(value[0])] : [])
    : typeof value === 'object' ? Object.fromEntries(Object.keys(value).sort().map(key => [key, shape(value[key])])) : typeof value;
const reading = (overrides = {}) => ({ ...statsFixture.base, ...overrides });
const hex = n => n.toString(16).padStart(64, '0');

function scenario(db) {
    const one = async (sql, params = []) => (await db.query(sql, params)).rows[0]?.r;
    const api = {
        db, one,
        async user(n, username, firstName = username) {
            await asAdmin(db);
            await db.query('insert into auth.users(id) values ($1) on conflict do nothing', [uid(n)]);
            await as(db, uid(n));
            await one('select public.textual_upsert_profile($1, $2, $3) r', [uid(n), firstName, username]);
            return uid(n);
        },
        async sync(user, changes, since = 0) {
            await as(db, user);
            return one('select public.textual_sync_library(p_expected_user_id => $1, p_changes => $2::jsonb, p_since_revision => $3, p_limit => 500) r',
                [user, JSON.stringify(changes), since]);
        },
        // One library mutation, tracking each entry's revision like the app does.
        revisions: new Map(),
        async save(user, entry, { title = 'Untitled', author = 'Writer', provider = 'openlibrary', providerId,
                                  data = reading(), activity, deleted = false, operation = randomUUID() } = {}) {
            const key = `${user}:${entry}`;
            const change = { operation_id: operation, entry_id: entry, expected_revision: api.revisions.get(key) ?? 0,
                deleted, book: { provider, provider_id: providerId, title, author }, reading_data: data };
            if (activity) change.activity = activity;
            const response = await api.sync(user, [change]);
            const result = response.results[0];
            if (result.status === 'applied') api.revisions.set(key, result.entry.revision);
            return { response, result, change };
        },
        async settings(user) { await as(db, user); return one('select public.textual_social_settings() r'); },
        async setSettings(user, settings) {
            await as(db, user);
            return one('select public.textual_update_social_settings($1, $2::jsonb) r', [user, JSON.stringify(settings)]);
        },
        async friendship(user, action, target, requestId = null, operation = randomUUID()) {
            await as(db, user);
            return one(`select public.textual_update_friendship(p_expected_user_id => $1, p_operation_id => $2,
                p_action => $3, p_target => $4, p_request_id => $5) r`, [user, operation, action, target, requestId]);
        },
        async befriend(a, b) {
            const sent = await api.friendship(a, 'send', b);
            const accepted = await api.friendship(b, 'accept', a, sent.relationship.request_id);
            assert.equal(accepted.outcome, 'accepted');
            return accepted.relationship.request_id;
        },
        async profile(user, username) { await as(db, user); return one('select public.textual_read_public_profile($1) r', [username]); },
        async legacyProfile(user, username) { await as(db, user); return one('select public.textual_read_reader_profile($1) r', [username]); },
        async books(user, username, list, after = null, limit = 30) {
            await as(db, user);
            return one('select public.textual_read_profile_books($1, $2, $3, $4, $5) r',
                [username, list, after?.title ?? null, after?.id ?? null, limit]);
        },
        async allBooks(user, username, list, limit = 30) {
            const seen = []; let after = null; let first = null; let pages = 0;
            do {
                const page = await api.books(user, username, list, after, limit);
                first = first ?? page; pages++;
                seen.push(...page.books); after = page.next;
            } while (after && pages < 50);
            return { books: seen, total: first.total, pages };
        },
        async feed(user, { cutoff = null, before = null, limit = 25 } = {}) {
            await as(db, user);
            return one('select public.textual_read_feed($1, $2, $3, $4) r', [cutoff, before?.published_at ?? null, before?.id ?? null, limit]);
        },
        async allFeed(user, limit = 25) {
            const events = []; let before = null; let cutoff = null; let pages = 0;
            do {
                const page = await api.feed(user, { cutoff, before, limit });
                cutoff = page.cutoff; pages++;
                events.push(...page.events); before = page.next;
            } while (before && pages < 100);
            return events;
        },
        async discovery(user, { snapshot = null, after = null, limit = 24 } = {}) {
            await as(db, user);
            return one('select public.textual_read_friend_discovery($1, $2, $3, $4) r',
                [snapshot, after?.score ?? null, after?.book_id ?? null, limit]);
        },
        async allDiscovery(user, limit = 24) {
            const books = []; let after = null; let snapshot = null; let pages = 0; let first;
            do {
                const page = await api.discovery(user, { snapshot, after, limit });
                first = first ?? page; snapshot = page.snapshot; pages++;
                books.push(...page.books); after = page.next;
            } while (after && pages < 100);
            return { books, hasFriends: first.has_friends };
        },
        async publish(user, revision, content, activity) {
            await as(db, user);
            if (activity === undefined) {
                return one('select public.textual_publish_reader_profile(p_expected_user_id => $1, p_expected_revision => $2, p_content => $3::jsonb) r',
                    [user, revision, JSON.stringify(content)]);
            }
            return one('select public.textual_publish_reader_profile(p_expected_user_id => $1, p_expected_revision => $2, p_content => $3::jsonb, p_activity => $4::jsonb) r',
                [user, revision, JSON.stringify(content), JSON.stringify(activity)]);
        },
        async review(user, book, revision, content, { deleted = false, activity, operation = randomUUID() } = {}) {
            await as(db, user);
            if (activity === undefined) {
                return one(`select public.textual_save_review(p_expected_user_id => $1, p_operation_id => $2, p_book_id => $3,
                    p_expected_revision => $4, p_content => $5::jsonb, p_deleted => $6) r`,
                    [user, operation, book, revision, JSON.stringify(content), deleted]);
            }
            return one(`select public.textual_save_review(p_expected_user_id => $1, p_operation_id => $2, p_book_id => $3,
                p_expected_revision => $4, p_content => $5::jsonb, p_deleted => $6, p_activity => $7::jsonb) r`,
                [user, operation, book, revision, JSON.stringify(content), deleted, JSON.stringify(activity)]);
        },
        async activityRows(user) {
            await asAdmin(db);
            return (await db.query('select kind, read_number, eligible, quote_id, favorite_id from public.textual_activity where actor_id = $1 order by published_at, id', [user])).rows;
        },
        async bookID(provider, providerId) {
            await asAdmin(db);
            return (await db.query('select id from public.textual_books where provider = $1 and provider_id = $2', [provider, providerId])).rows[0]?.id;
        }
    };
    return api;
}

async function intent(api, user, kind, extra = {}) {
    const settings = await api.settings(user);
    return { id: randomUUID(), kind, shared: true, sharing_version: Number(settings.sharingVersion),
             occurred_at: new Date().toISOString(), ...extra };
}

const card = (favorites = [], extra = {}) => ({
    stats: { reads: 0, genres: 0, rereads: 0 }, sentence: 'new to the library. judgment pending, fondly.', favorites, ...extra });
const favorite = (id, n, title = `Shelf ${n}`) => ({ id, title, author: 'Writer', isbn: '', coverURL: `https://covers.openlibrary.org/b/id/${n}-L.jpg`, catalogID: `openlibrary:OL${n}W` });
const reviewContent = (extra = {}) => ({ version: 1, body: 'Loved it', spoilers: false, moods: [], visibility: 'private', contribute: false, ...extra });

const cluster = await startCluster();
try {
    // =====================================================================
    // Scenario 1: existing data, then migrate (simulates the live project).
    // =====================================================================
    {
        const db = await cluster.createDatabase('existing');
        await applyMigrations(db, BASE_MIGRATIONS);
        const t = scenario(db);
        const A = await t.user(1, 'ada_reads', 'Ada');
        const B = await t.user(2, 'bea', 'Bea');
        const e1 = randomUUID(), e2 = randomUUID();
        await t.save(A, e1, { title: 'Dune', providerId: 'OL1W', data: reading({ status: 'read', readCount: 2 }) });
        await t.save(A, e2, { title: 'Emma', providerId: 'OL2W', data: reading({ status: 'read' }) });
        await t.publish(A, 0, card([favorite(randomUUID(), 1, 'Dune')], { stats: { reads: 3, genres: 2, rereads: 1 } }));
        const duneBook = await t.bookID('openlibrary', 'OL1W');
        await t.review(A, duneBook, 0, reviewContent());
        await asAdmin(db);
        const snapshot = async () => (await db.query(`select
            (select jsonb_agg(to_jsonb(e) - 'completed_reads' order by e.id) from public.textual_library_entries e) entries,
            (select jsonb_agg(to_jsonb(r) - 'updated_at' order by r.user_id) from public.textual_reviews r) reviews,
            (select jsonb_agg(to_jsonb(p) order by p.user_id) from public.textual_reader_profiles p) cards`)).rows[0];
        const before = await snapshot();

        await applyMigrations(db, SOCIAL_MIGRATIONS);
        await asAdmin(db);
        eq(await snapshot(), before, 'migration preserves library entries, reviews, and cards');
        eq((await db.query('select title, completed_reads from public.textual_library_entries order by title')).rows,
            [{ title: 'Dune', completed_reads: 2 }, { title: 'Emma', completed_reads: 1 }], 'existing rows get their completed reads computed');
        const migrated = (await db.query('select activity_sharing, sharing_version, books_read_visible, genres_visible, rereads_visible from public.textual_profiles where user_id = $1', [A])).rows[0];
        eq(migrated, { activity_sharing: true, sharing_version: '1', books_read_visible: false, genres_visible: false, rereads_visible: false },
            'existing accounts keep their read lists private until they choose otherwise');
        eq((await db.query('select count(*)::int n from public.textual_activity')).rows[0].n, 0, 'migration publishes no historical activity');

        const visitor = await t.profile(B, 'ada_reads');
        eq(visitor.card, { books_read: { visible: false }, genres: { visible: false }, rereads: { visible: false } }, 'hidden card details return no counts');
        eq((await t.legacyProfile(B, 'ada_reads')).content.stats, { reads: 0, genres: 0, rereads: 0 }, 'old app versions see hidden counts as zero');
        eq((await t.legacyProfile(A, 'ada_reads')).content.stats, { reads: 3, genres: 2, rereads: 1 }, 'owner keeps the exact published card');
        await rejects(() => t.books(B, 'ada_reads', 'read'), '42501', 'hidden Books Read list is denied directly');
        eq((await t.profile(A, 'ada_reads')).card.books_read, { visible: true, count: 3, books: 2 }, 'owner always sees own details');

        // Current app versions keep working against the migrated schema.
        const legacyCard = await t.publish(A, 1, card([], { stats: { reads: 3, genres: 2, rereads: 1 } }));
        eq(legacyCard.revision, 2, 'three-argument card publish still works');
        eq((await t.review(A, duneBook, 1, reviewContent({ body: 'Still loved it' }))).status, 'applied', 'six-argument review save still works');
        eq((await t.save(A, e2, { title: 'Emma', providerId: 'OL2W', data: reading({ status: 'read', readCount: 2 }) })).result.status, 'applied',
            'library sync without activity still works');
        eq((await t.activityRows(A)).length, 0, 'old-client writes create no activity');

        const C = await t.user(3, 'cleo', 'Cleo');
        const fresh = await t.settings(C);
        eq(fresh, { activitySharing: true, sharingVersion: 1, booksReadVisible: true, genresVisible: true, rereadsVisible: true,
                    activityEnabled: true },
            'profiles created after the migration get the visible defaults');
        await t.setSettings(A, { booksReadVisible: true });
        eq((await t.profile(B, 'ada_reads')).card.books_read, { visible: true, count: 2, books: 2 },
            'enabled Books Read with hidden rereads counts distinct books only');
        await db.end();
    }

    // =====================================================================
    // Staged deployment: 011 applied, 012 not yet. Current and new app versions work.
    // =====================================================================
    {
        const db = await cluster.createDatabase('staged');
        await applyMigrations(db, [...BASE_MIGRATIONS, SOCIAL_MIGRATIONS[0]]);
        const t = scenario(db);
        const A = await t.user(1, 'ada_reads', 'Ada');
        ok(!('activityEnabled' in await t.settings(A)), 'without 012 the app is not told to send activity');
        eq((await t.save(A, randomUUID(), { title: 'Dune', providerId: 'OL1W', data: reading({ status: 'read' }) })).result.status, 'applied',
            'library sync without intents works on the staged database');
        const staged = await t.publish(A, 0, card([], { genreBreakdown: [{ name: 'Fantasy', books: 1, reads: 1 }] }));
        eq(staged.content.genreBreakdown, [{ name: 'Fantasy', books: 1, reads: 1 }], 'the breakdown publishes with 011 alone');
        await rejects(() => t.sync(A, [{ operation_id: randomUUID(), entry_id: randomUUID(), expected_revision: 0, deleted: false,
            book: { provider: 'openlibrary', provider_id: 'OL2W', title: 'Emma', author: 'Writer' }, reading_data: reading(), activity: [] }]),
            '22023', 'intents are only accepted once 012 is applied (the app checks activityEnabled first)');
        await asAdmin(db);
        await applyMigrations(db, [SOCIAL_MIGRATIONS[1]]);
        eq((await t.settings(A)).activityEnabled, true, 'after 012 the capability is advertised');
        await db.end();
    }

    // =====================================================================
    // Scenario 2: fresh database with every migration.
    // =====================================================================
    const db = await cluster.createDatabase('fresh');
    await applyMigrations(db, [...BASE_MIGRATIONS, ...SOCIAL_MIGRATIONS]);
    const t = scenario(db);
    const A = await t.user(1, 'ada_reads', 'Ada');
    const B = await t.user(2, 'bea', 'Bea');
    const C = await t.user(3, 'cleo', 'Cleo');
    const D = await t.user(4, 'dot_com', 'Dorothy');
    const E = await t.user(5, 'ada_lovelace', 'Ada');

    // ---------------- Stats parity with ReadingStatsFilter.completedCount ----------------
    await asAdmin(db);
    for (const testCase of statsFixture.cases) {
        const n = (await db.query('select public.textual_completed_count($1::jsonb) n', [JSON.stringify(reading(testCase.reading))])).rows[0].n;
        eq(n, testCase.completed, `completed count: ${testCase.name}`);
    }

    // ---------------- Friendships ----------------
    const sent = await t.friendship(A, 'send', B);
    eq([sent.outcome, sent.relationship.state], ['requested', 'outgoing'], 'send creates an outgoing request');
    captured.friendship_result = sent;
    eq((await t.friendship(A, 'send', B)).outcome, 'already_requested', 'duplicate send is idempotent');
    const opposite = await t.friendship(B, 'send', A);
    eq([opposite.outcome, opposite.relationship.state], ['incoming_pending', 'incoming'], 'opposite send shows the incoming request without accepting it');
    await asAdmin(db);
    eq((await db.query("select count(*)::int n from public.textual_friendships where status <> 'none'")).rows[0].n, 1, 'one pending relationship per pair');
    await rejects(() => t.friendship(A, 'send', A), '22023', 'self-requests are rejected');
    eq((await t.friendship(A, 'accept', B, sent.relationship.request_id)).outcome, 'stale', 'the sender cannot accept their own request');
    eq((await t.friendship(C, 'accept', A, sent.relationship.request_id)).outcome, 'stale', 'an unrelated reader cannot accept someone else’s request');
    eq((await t.friendship(C, 'cancel', B, sent.relationship.request_id)).outcome, 'stale', 'an unrelated reader cannot cancel someone else’s request');
    eq((await t.friendship(B, 'cancel', A, sent.relationship.request_id)).outcome, 'stale', 'only the sender can cancel');
    const acceptOp = randomUUID();
    const accepted = await t.friendship(B, 'accept', A, sent.relationship.request_id, acceptOp);
    eq([accepted.outcome, accepted.relationship.state], ['accepted', 'friends'], 'the recipient accepts');
    eq((await t.friendship(B, 'accept', A, sent.relationship.request_id, acceptOp)).outcome, 'accepted', 'an accept retry returns the original outcome');
    await rejects(() => t.friendship(B, 'decline', A, sent.relationship.request_id, acceptOp), '22023', 'an operation ID cannot be reused for another action');
    const friendsRequest = accepted.relationship.request_id;
    eq((await t.friendship(A, 'remove', B, friendsRequest)).outcome, 'removed', 'either participant removes');
    eq((await t.friendship(B, 'accept', A, sent.relationship.request_id)).outcome, 'stale', 'a stale accept cannot resurrect a removed friendship');
    const retried = await t.friendship(B, 'accept', A, sent.relationship.request_id, acceptOp);
    eq([retried.outcome, retried.relationship.state], ['accepted', 'none'], 'a retried accept reports its outcome without resurrecting the friendship');
    // Delayed cancellation cannot remove a later request.
    const first = await t.friendship(A, 'send', B);
    eq((await t.friendship(A, 'cancel', B, first.relationship.request_id)).outcome, 'cancelled', 'sender cancels');
    const second = await t.friendship(A, 'send', B);
    eq((await t.friendship(A, 'cancel', B, first.relationship.request_id)).outcome, 'stale', 'a delayed cancel carries an old request ID');
    eq((await t.friendship(B, 'decline', A, second.relationship.request_id)).outcome, 'declined', 'the recipient declines');
    await rejects(() => t.friendship(A, 'send', B), 'PT429', 'repeated requests to one reader are rate limited');
    eq((await t.friendship(A, 'send', D)).outcome, 'requested', 'other readers are unaffected by a per-pair limit');

    // Concurrent races with two real connections.
    const other = await cluster.connect('fresh');
    const race = scenario(other);
    {
        // Opposite first requests: B's transaction holds the new pair row; A waits on it.
        await as(db, C); await as(other, B);
        await other.query('begin');
        const bFirst = await other.query(`select public.textual_update_friendship($1, $2, 'send', $3) r`, [B, randomUUID(), C]);
        const cWaiting = db.query(`select public.textual_update_friendship($1, $2, 'send', $3) r`, [C, randomUUID(), B]);
        await new Promise(resolve => setTimeout(resolve, 150));
        await other.query('commit');
        const cResult = (await cWaiting).rows[0].r;
        eq([bFirst.rows[0].r.outcome, cResult.outcome], ['requested', 'incoming_pending'], 'concurrent opposite requests keep one pending request');
        // Concurrent accept and cancel: whichever commits first wins; the other is stale.
        const request = bFirst.rows[0].r.relationship.request_id;
        await as(other, C);
        await other.query('begin');
        const acceptFirst = (await other.query(`select public.textual_update_friendship($1, $2, 'accept', $3, $4) r`, [C, randomUUID(), B, request])).rows[0].r;
        await as(db, B);
        const cancelWaiting = db.query(`select public.textual_update_friendship($1, $2, 'cancel', $3, $4) r`, [B, randomUUID(), C, request]);
        await new Promise(resolve => setTimeout(resolve, 150));
        await other.query('commit');
        eq([acceptFirst.outcome, (await cancelWaiting).rows[0].r.outcome], ['accepted', 'stale'], 'a cancel racing an accept never removes the friendship');
        eq((await t.friendship(B, 'remove', C, request)).outcome, 'removed', 'cleanup');
    }

    // Friend list and graph privacy. (Simulate the per-pair request window passing.)
    await asAdmin(db);
    await db.query("update public.textual_friendships set recent_window_start = now() - interval '8 days'");
    const abRequest = await t.befriend(A, B);
    await t.befriend(A, D);
    await as(db, A);
    const listed = await t.one('select public.textual_list_friends() r');
    eq(listed.friends.map(f => f.username), ['bea', 'dot_com'], 'friends are listed by username');
    captured.friends_page = listed;
    captured.settings = await t.settings(A);
    eq(listed.friends[0].relationship.request_id, abRequest, 'the list carries the request ID needed to remove');
    const publicFriends = await t.one('select public.textual_read_profile_friends($1, $2, $3) r', ['ada_reads', null, 1]);
    eq(publicFriends.friends.map(f => f.username), ['bea'], 'public profile friends preview is paged');
    eq(publicFriends.next, 'bea', 'public profile friends cursor is stable');
    eq((await t.one('select public.textual_read_profile_friends($1, $2, $3) r', ['ada_reads', publicFriends.next, 1]))
        .friends.map(f => f.username), ['dot_com'], 'the next public friends page is complete');
    await as(db, C);
    eq((await t.one('select public.textual_list_friends() r')).friends, [], 'an unrelated reader sees none of A’s friends');
    eq((await t.one('select public.textual_read_profile_friends($1) r', ['ada_reads'])).friends
        .map(f => [f.username, f.relationship.state]), [['bea', 'none'], ['dot_com', 'none']],
        'visitor sees accepted friends and only their own relationship to each');
    for (const table of ['textual_friendships', 'textual_activity', 'textual_social_operations',
                         'textual_social_rate_limits', 'textual_profile_genres']) {
        await as(db, A);
        await rejects(() => db.query(`select * from public.${table}`), '42501', `${table} has no direct client access`);
    }
    await as(db, A);
    eq((await db.query('select user_id from public.textual_profiles')).rows.map(r => r.user_id), [A], 'profile rows (and privacy settings) stay owner-only');

    // ---------------- Search ----------------
    await as(db, A);
    const search = await t.one('select public.textual_search_readers($1) r', ['ada']);
    eq(search.results.map(r => r.username), ['ada_lovelace'], 'search excludes the viewer and matches usernames');
    captured.search_page = search;
    eq(Object.keys(search.results[0]).sort(), ['avatar_path', 'first_name', 'rank', 'relationship', 'user_id', 'username'],
        'search returns public identity and the viewer’s relationship only');
    eq((await t.one('select public.textual_search_readers($1) r', ['BEA'])).results[0].relationship.state, 'friends', 'search is case-insensitive and shows relationship');
    eq((await t.one('select public.textual_search_readers($1) r', ['doro'])).results.map(r => r.username), ['dot_com'], 'search matches first names');
    eq((await t.one('select public.textual_search_readers($1) r', ['__'])).results, [], 'underscores are literal, not wildcards');
    eq((await t.one('select public.textual_search_readers($1) r', ['a'])).results, [], 'one-character searches return nothing');
    await asAdmin(db);
    for (let n = 0; n < 7; n++) await t.user(100 + n, `zed_${n}`, 'Zed');
    await as(db, A);
    const pages = []; let after = null;
    do {
        const page = await t.one('select public.textual_search_readers($1, $2, $3, $4) r', ['zed', after?.rank ?? null, after?.username ?? null, 3]);
        pages.push(...page.results.map(r => r.username)); after = page.next;
    } while (after);
    eq(pages, ['zed_0', 'zed_1', 'zed_2', 'zed_3', 'zed_4', 'zed_5', 'zed_6'], 'search pagination is stable and complete');
    await as(db, E);
    for (let n = 0; n < 60; n++) await t.one('select public.textual_search_readers($1) r', ['zed']);
    await rejects(() => t.one('select public.textual_search_readers($1) r', ['zed']), 'PT429', 'search is rate limited on the server');

    // ---------------- Library card details ----------------
    const editions = [];
    for (let n = 0; n < 75; n++) {
        const entry = randomUUID();
        const times = n % 10 === 0 ? 3 : 1; // eight rereads among 75 books
        await t.save(B, entry, { title: `Book ${String(n).padStart(2, '0')}`, providerId: `OL${1000 + n}W`,
            data: reading({ status: 'read', readCount: times }) });
        editions.push(entry);
    }
    // Two editions of one work are two books, never a reread.
    await t.save(B, randomUUID(), { title: 'Persuasion', providerId: 'OL2001W', data: reading({ status: 'read' }) });
    await t.save(B, randomUUID(), { title: 'Persuasion', provider: 'google', providerId: 'persuasion-ed2', data: reading({ status: 'read' }) });
    await t.save(B, randomUUID(), { title: 'Unread', providerId: 'OL2002W', data: reading({ status: 'to-read' }) });
    const removed = randomUUID();
    await t.save(B, removed, { title: 'Removed', providerId: 'OL2003W', data: reading({ status: 'read' }) });
    await t.save(B, removed, { title: 'Removed', providerId: 'OL2003W', data: reading({ status: 'read' }), deleted: true });
    const breakdown = [{ name: 'Fantasy', books: 40, reads: 56 }, { name: 'Romance', books: 30, reads: 30 }, { name: 'Unclassified', books: 7, reads: 7 }];
    await t.publish(B, 0, card([favorite(randomUUID(), 2001, 'Persuasion')], { genreBreakdown: breakdown }));

    const fullRead = await t.allBooks(C, 'bea', 'read');
    eq(fullRead.books.length, 77, 'Books Read lists every completed book, across pages');
    eq(fullRead.total, 77, 'the first page total matches the list');
    eq(new Set(fullRead.books.map(b => b.entry_id)).size, 77, 'no duplicate books across pages');
    const sorted = [...fullRead.books].sort((x, y) => x.sort_title < y.sort_title ? -1 : x.sort_title > y.sort_title ? 1 : x.entry_id < y.entry_id ? -1 : 1);
    eq(fullRead.books.map(b => b.entry_id), sorted.map(b => b.entry_id), 'title order with ID tie-break');
    ok(fullRead.books.every(b => b.source === 'books_read' && !('rating' in b) && !('times_read' in b)), 'list carries its permission source and no ratings');
    ok(!fullRead.books.some(b => b.title === 'Removed' || b.title === 'Unread'), 'removed and unread books are excluded');
    const rereads = await t.allBooks(C, 'bea', 'rereads');
    eq(rereads.books.length, 8, 'rereads lists books read more than once');
    ok(!rereads.books.some(b => b.title === 'Persuasion'), 'a second edition is not a reread');
    const visitorCard = (await t.profile(C, 'bea')).card;
    eq(visitorCard.books_read, { visible: true, count: 77 + 16, books: 77 }, 'Books Read count includes rereads when rereads are visible');
    eq(visitorCard.rereads, { visible: true, count: rereads.books.reduce((s, b) => s + b.times_read - 1, 0), books: 8 }, 'reread count matches its list');
    eq(visitorCard.genres, { visible: true, count: 2, breakdown }, 'genre count excludes Unclassified and matches the breakdown');
    captured.public_profile = await t.profile(C, 'bea');
    captured.books_page = await t.books(C, 'bea', 'rereads', null, 2);

    const mapped = [
        { entry_id: fullRead.books[0].entry_id, genres: ['Fantasy'] },
        { entry_id: fullRead.books[1].entry_id, genres: ['Fantasy', 'Romance'] },
        { entry_id: fullRead.books[2].entry_id, genres: [] }
    ];
    await as(db, B);
    eq(await t.one('select public.textual_publish_profile_genres($1, $2::jsonb) r', [B, JSON.stringify(mapped)]), true,
        'owner can publish per-book genres');
    await as(db, C);
    eq((await t.one('select public.textual_read_profile_genre_books($1, $2) r', ['bea', 'Fantasy'])).books
        .map(b => b.entry_id), mapped.slice(0, 2).map(b => b.entry_id), 'genre drilldown shows only matching covers');
    eq((await t.one('select public.textual_read_profile_genre_books($1, $2) r', ['bea', 'Unclassified'])).books
        .map(b => b.entry_id), [mapped[2].entry_id], 'unclassified drilldown includes uncategorized books');
    await rejects(() => t.one('select public.textual_publish_profile_genres($1, $2::jsonb) r', [C, JSON.stringify(mapped)]),
        '22023', 'a reader cannot publish another reader’s book IDs');
    await as(db, A);
    await rejects(() => t.one('select public.textual_publish_profile_genres($1, $2::jsonb) r', [B, JSON.stringify(mapped)]),
        '42501', 'a reader cannot publish another reader’s genres');

    await t.setSettings(B, { rereadsVisible: false });
    const noRereads = (await t.profile(C, 'bea')).card;
    eq(noRereads.books_read, { visible: true, count: 77, books: 77 }, 'hidden rereads: Books Read counts distinct books');
    eq(noRereads.genres.breakdown, breakdown.map(({ reads, ...rest }) => rest), 'hidden rereads: genre breakdown drops read counts');
    eq(noRereads.rereads, { visible: false }, 'hidden rereads return no count');
    await rejects(() => t.books(C, 'bea', 'rereads'), '42501', 'hidden rereads list is denied directly');
    eq((await t.legacyProfile(C, 'bea')).content.stats, { reads: 77, genres: 2, rereads: 0 }, 'the old read path applies the same rules');
    ok(!('genreBreakdown' in (await t.legacyProfile(C, 'bea')).content), 'the old read path never returns the breakdown');
    await t.setSettings(B, { booksReadVisible: false, genresVisible: false });
    const hidden = (await t.profile(A, 'bea')).card;
    eq(hidden, { books_read: { visible: false }, genres: { visible: false }, rereads: { visible: false } }, 'friends are denied disabled details too');
    await rejects(() => t.books(A, 'bea', 'read'), '42501', 'friends cannot page a hidden list');
    await rejects(() => t.one('select public.textual_read_profile_genre_books($1, $2) r', ['bea', 'Fantasy']),
        '42501', 'friends cannot browse a hidden genre');
    eq((await t.profile(B, 'bea')).card.books_read.count, 93, 'owner access is preserved while hidden');
    eq((await t.allBooks(B, 'bea', 'read')).books.length, 77, 'owner can still list');
    await t.setSettings(B, { booksReadVisible: true, genresVisible: true, rereadsVisible: true });
    // A cursor is not a permission: hiding mid-browse stops the next page.
    const pageOne = await t.books(C, 'bea', 'read');
    await t.setSettings(B, { booksReadVisible: false });
    await rejects(() => t.books(C, 'bea', 'read', pageOne.next), '42501', 'each page re-checks permission');
    await t.setSettings(B, { booksReadVisible: true });
    await rejects(() => t.setSettings(A, { booksReadVisible: 'yes' }), '22023', 'settings are validated');
    await as(db, A);
    await rejects(() => db.query('select public.textual_update_social_settings($1, $2::jsonb)', [B, '{"activitySharing": false}']), '42501',
        'nobody can change another reader’s privacy');
    // Invalid breakdowns are rejected at publish time.
    await rejects(() => t.publish(B, 1, card([], { genreBreakdown: [{ name: 'Fantasy', books: 2, reads: 1 }] })), undefined, 'reads below books');
    await rejects(() => t.publish(B, 1, card([], { genreBreakdown: [{ name: 'Fantasy', books: 1, reads: 1, extra: 1 }] })), undefined, 'extra fields');
    await rejects(() => t.publish(B, 1, card([], { genreBreakdown: [{ name: 'X', books: 1, reads: 1 }, { name: 'X', books: 1, reads: 1 }] })), undefined, 'duplicate genres');

    // ---------------- Activity generation ----------------
    const dune = randomUUID();
    const started = await intent(t, B, 'started');
    await t.save(B, dune, { title: 'Dune', providerId: 'OL3001W', data: reading({ status: 'currently-reading' }), activity: [started] });
    const finished = await intent(t, B, 'finished');
    const finishOp = randomUUID();
    const finishChange = await t.save(B, dune, { title: 'Dune', providerId: 'OL3001W', operation: finishOp,
        data: reading({ status: 'read', readCount: 1, periods: [{ startedOn: null, finishedOn: '2026-10-01' }] }), activity: [finished] });
    eq((await t.activityRows(B)).map(r => [r.kind, r.read_number, r.eligible]), [['started', 1, true], ['finished', 1, true]], 'start and finish are recorded once');
    // Crash after commit: the same operation is retried with an identical payload.
    const replay = await t.sync(B, [finishChange.change]);
    eq(replay.results[0].status, 'applied', 'the retried operation returns the original result');
    eq((await t.activityRows(B)).length, 2, 'a retried operation creates no duplicate activity');
    // A new operation re-sending the same intent is deduplicated by transition ID.
    await t.save(B, dune, { title: 'Dune', providerId: 'OL3001W', data: reading({ status: 'read', readCount: 1, periods: [{ startedOn: null, finishedOn: '2026-10-01' }], format: 'ebook' }), activity: [finished] });
    eq((await t.activityRows(B)).length, 2, 'a re-sent intent is not a new action');
    // Unchanged state with a new intent is not a transition.
    await t.save(B, dune, { title: 'Dune', providerId: 'OL3001W', data: reading({ status: 'read', readCount: 1, periods: [{ startedOn: null, finishedOn: '2026-10-01' }], format: 'paper' }), activity: [await intent(t, B, 'finished')] });
    eq((await t.activityRows(B)).length, 2, 'no event without a verified transition');
    // A reread is a new session with distinct read numbers.
    await t.save(B, dune, { title: 'Dune', providerId: 'OL3001W', data: reading({ status: 'currently-reading', readCount: 1, periods: [{ startedOn: null, finishedOn: '2026-10-01' }] }), activity: [await intent(t, B, 'started')] });
    await t.save(B, dune, { title: 'Dune', providerId: 'OL3001W', data: reading({ status: 'read', readCount: 2, periods: [{ startedOn: null, finishedOn: '2026-10-01' }, { startedOn: null, finishedOn: '2026-10-10' }] }), activity: [await intent(t, B, 'finished')] });
    eq((await t.activityRows(B)).map(r => [r.kind, r.read_number]), [['started', 1], ['finished', 1], ['started', 2], ['finished', 2]], 'rereads stay distinct');
    // Toggling status back and forth does not repeat "started".
    await t.save(B, dune, { title: 'Dune', providerId: 'OL3001W', data: reading({ status: 'currently-reading', readCount: 2 }), activity: [await intent(t, B, 'started')] });
    await t.save(B, dune, { title: 'Dune', providerId: 'OL3001W', data: reading({ status: 'to-read', readCount: 2 }) });
    await t.save(B, dune, { title: 'Dune', providerId: 'OL3001W', data: reading({ status: 'currently-reading', readCount: 2 }), activity: [await intent(t, B, 'started')] });
    eq((await t.activityRows(B)).filter(r => r.kind === 'started').length, 3, 'one start per read session');
    // Offline coalescing: start + finish in one change.
    const emma = randomUUID();
    await t.save(B, emma, { title: 'Emma', providerId: 'OL3002W', data: reading({ status: 'read', readCount: 1 }),
        activity: [await intent(t, B, 'started'), await intent(t, B, 'finished')] });
    eq((await t.activityRows(B)).slice(-2).map(r => r.kind), ['started', 'finished'], 'coalesced offline actions verify together');
    // Imports, downloads, and old clients: reading data with no intent.
    const imported = randomUUID();
    await t.save(B, imported, { title: 'Imported', providerId: 'OL3003W', data: reading({ status: 'read', readCount: 4 }) });
    eq((await t.activityRows(B)).length, 7, 'imports publish nothing');
    // Quotes: only a quote ID that is new in this change.
    const quoteID = randomUUID().toUpperCase(); // Swift encodes UUIDs in uppercase
    const journal = text => ({ journal: { quotes: [{ id: quoteID, text, createdAt: 0, page: 12 }], notes: [{ id: randomUUID(), text: 'private note', createdAt: 0 }] } });
    await t.save(B, emma, { title: 'Emma', providerId: 'OL3002W', data: reading({ status: 'read', readCount: 1, ...journal('Badly done, Emma!') }),
        activity: [await intent(t, B, 'quote', { quote_id: quoteID }), await intent(t, B, 'quote', { quote_id: randomUUID() })] });
    eq((await t.activityRows(B)).filter(r => r.kind === 'quote').length, 1, 'only the newly saved quote is recorded');
    await t.save(B, emma, { title: 'Emma', providerId: 'OL3002W', data: reading({ status: 'read', readCount: 1, ...journal('Badly done, Emma!'), format: 'x' }),
        activity: [await intent(t, B, 'quote', { quote_id: quoteID })] });
    eq((await t.activityRows(B)).filter(r => r.kind === 'quote').length, 1, 'an existing quote cannot be posted again');
    // Malformed intents never break sync.
    const odd = await t.save(B, emma, { title: 'Emma', providerId: 'OL3002W', data: reading({ status: 'read', readCount: 1, ...journal('Badly done, Emma!'), format: 'y' }),
        activity: [{ id: 'nope', kind: 'finished' }, { ...(await intent(t, B, 'finished')), extra: true }] });
    eq(odd.result.status, 'applied', 'malformed intents are ignored, never fatal to sync');

    // ---------------- Feed ----------------
    let feed = await t.allFeed(A);
    eq(feed.map(e => e.kind).sort(), ['finished', 'finished', 'finished', 'quote', 'started', 'started', 'started', 'started'].sort(), 'a friend sees eligible activity');
    const quoteEvent = feed.find(e => e.kind === 'quote');
    captured.feed_page = await t.feed(A, { limit: 2 });
    eq([quoteEvent.quote.text, quoteEvent.quote.page, quoteEvent.book.title, quoteEvent.actor.username], ['Badly done, Emma!', 12, 'Emma', 'bea'], 'quote is rendered from its source');
    ok(!JSON.stringify(feed).includes('private note'), 'notes never appear in the feed');
    ok(!JSON.stringify(feed).includes('readCount') && !JSON.stringify(feed).includes('periods'), 'no archive fields in feed payloads');
    eq(await t.allFeed(C), [], 'an unrelated reader sees no friends-only activity');
    await as(db, null);
    await rejects(() => db.query('select public.textual_read_feed()'), '42501', 'signed-out callers cannot read the feed');
    // Edits update in place; deletions remove the event.
    await t.save(B, emma, { title: 'Emma', providerId: 'OL3002W', data: reading({ status: 'read', readCount: 1, ...journal('Badly done, indeed!') }) });
    feed = await t.allFeed(A);
    eq(feed.find(e => e.kind === 'quote').quote.text, 'Badly done, indeed!', 'quote edits update the existing event');
    eq((await t.activityRows(B)).filter(r => r.kind === 'quote').length, 1, 'editing creates no new post');
    await t.save(B, emma, { title: 'Emma', providerId: 'OL3002W', data: reading({ status: 'read', readCount: 1 }) });
    ok(!(await t.allFeed(A)).some(e => e.kind === 'quote'), 'a deleted quote disappears');

    // Reviews: only shared reviews; edits stay one post; privacy or deletion removes it.
    const emmaBook = await t.bookID('openlibrary', 'OL3002W');
    let review = await t.review(B, emmaBook, 0, reviewContent({ rating: 18 }), { activity: [await intent(t, B, 'review')] });
    ok(!(await t.allFeed(A)).some(e => e.kind === 'review'), 'a private review is never activity');
    review = await t.review(B, emmaBook, 1, reviewContent({ rating: 18, visibility: 'public' }), { activity: [await intent(t, B, 'review')] });
    feed = await t.allFeed(A);
    eq(feed.find(e => e.kind === 'review').review, { rating: 18, body: 'Loved it', spoilers: false }, 'a shared review appears with its rating');
    review = await t.review(B, emmaBook, 2, reviewContent({ rating: 20, body: 'Even better', visibility: 'public' }), { activity: [await intent(t, B, 'review')] });
    eq((await t.allFeed(A)).filter(e => e.kind === 'review').map(e => e.review.body), ['Even better'], 'review edits update the single post');
    review = await t.review(B, emmaBook, 3, reviewContent({ rating: 20, visibility: 'private' }));
    ok(!(await t.allFeed(A)).some(e => e.kind === 'review'), 'making a review private removes it');
    review = await t.review(B, emmaBook, 4, reviewContent({ rating: 20, visibility: 'public' }), { activity: [await intent(t, B, 'review')] });
    eq((await t.activityRows(B)).filter(r => r.kind === 'review').length, 1, 're-sharing a review does not post again');
    // Tombstoned entries remove their events.
    await t.save(B, dune, { title: 'Dune', providerId: 'OL3001W', data: reading({ status: 'currently-reading', readCount: 2 }), deleted: true });
    ok(!(await t.allFeed(A)).some(e => e.book.title === 'Dune'), 'removing a book from the archive removes its activity');

    // Shelf additions.
    await as(db, B);
    const cardRevision = (await t.legacyProfile(B, 'bea')).revision;
    const shelfID = randomUUID().toUpperCase();
    await t.publish(B, cardRevision, card([favorite(randomUUID(), 2001, 'Persuasion'), favorite(shelfID, 3002, 'Emma')], { genreBreakdown: breakdown }),
        [await intent(t, B, 'shelf', { favorite_id: shelfID })]);
    feed = await t.allFeed(A);
    eq(feed.filter(e => e.kind === 'shelf').map(e => e.book.title), ['Emma'], 'adding to a public shelf is activity');
    captured.feed_page_shelf_review = { ...(await t.feed(A)), events: feed.filter(e => ['shelf', 'review'].includes(e.kind)) };
    await t.publish(B, cardRevision + 1, card([favorite(randomUUID(), 2001, 'Persuasion')], { genreBreakdown: breakdown }));
    ok(!(await t.allFeed(A)).some(e => e.kind === 'shelf'), 'removing from the shelf removes the event');
    await as(db, D);
    const recovered = await t.publish(D, 0, card([favorite(randomUUID(), 2001)]), []);
    eq((await t.activityRows(D)).length, 0, 'a published shelf without explicit add intents creates no activity');

    // ---------------- Sharing lifecycle ----------------
    const beforeOff = (await t.allFeed(A)).length;
    ok(beforeOff > 0, 'friend has visible activity');
    const queued = await intent(t, B, 'started'); // stamped before the toggle, sent later
    await t.setSettings(B, { activitySharing: false });
    eq((await t.allFeed(A)).length, 0, 'turning sharing off hides earlier activity on the next read');
    const whileOff = randomUUID();
    await t.save(B, whileOff, { title: 'Off', providerId: 'OL4001W', data: reading({ status: 'currently-reading' }), activity: [await intent(t, B, 'started')] });
    await t.setSettings(B, { activitySharing: true });
    eq((await t.allFeed(A)).length, beforeOff, 'turning sharing on restores only previously eligible activity');
    const late = randomUUID();
    await t.save(B, late, { title: 'Queued', providerId: 'OL4002W', data: reading({ status: 'currently-reading' }), activity: [queued] });
    eq((await t.activityRows(B)).filter(r => !r.eligible).length, 2, 'off-period and queued-before-toggle actions are never eligible');
    eq((await t.allFeed(A)).length, beforeOff, 'replaying a queued action after re-enabling does not publish it');
    await t.save(B, randomUUID(), { title: 'Now', providerId: 'OL4003W', data: reading({ status: 'currently-reading' }), activity: [await intent(t, B, 'started')] });
    eq((await t.allFeed(A)).length, beforeOff + 1, 'new actions after re-enabling publish');
    // Settings change racing an activity write: the share lock orders them.
    {
        const stamped = await intent(t, B, 'started');
        await as(other, B);
        await other.query('begin');
        await other.query(`select public.textual_update_social_settings($1, '{"activitySharing": false}'::jsonb)`, [B]);
        const entry = randomUUID();
        const change = { operation_id: randomUUID(), entry_id: entry, expected_revision: 0, deleted: false,
            book: { provider: 'openlibrary', provider_id: 'OL4004W', title: 'Race', author: 'Writer' },
            reading_data: reading({ status: 'currently-reading' }), activity: [stamped] };
        await as(db, B);
        const waiting = db.query('select public.textual_sync_library($1, $2::jsonb, 0, 1) r', [B, JSON.stringify([change])]);
        await new Promise(resolve => setTimeout(resolve, 150));
        await other.query('commit');
        await waiting;
        const raced = await t.activityRows(B);
        eq(raced[raced.length - 1].eligible, false, 'an action racing a sharing change uses the committed setting');
        await t.setSettings(B, { activitySharing: true });
    }

    // Read numbers reveal rereads: they follow the actor's Rereads setting.
    {
        const readsShown = (await t.allFeed(A)).filter(e => e.kind === 'finished' && e.actor.username === 'bea');
        ok(readsShown.every(e => Number.isInteger(e.read_number) && typeof e.read_key === 'string'), 'visible rereads include read numbers');
        await t.setSettings(B, { rereadsVisible: false });
        const readsHidden = (await t.allFeed(A)).filter(e => ['started', 'finished'].includes(e.kind) && e.actor.username === 'bea');
        ok(readsHidden.length > 0 && readsHidden.every(e => e.read_number === null && /^[0-9a-f]{32}$/.test(e.read_key)),
            'hidden rereads: no read numbers in the feed, only an opaque key');
        await t.setSettings(B, { rereadsVisible: true });
    }

    // Unfriend removes access immediately.
    await t.friendship(A, 'remove', B, abRequest);
    eq(await t.allFeed(A), [], 'unfriending removes the friend’s activity');
    const abAgain = await t.befriend(B, A);

    // ---------------- Feed pagination with identical timestamps ----------------
    await asAdmin(db);
    const tie = '2026-10-12T12:00:00Z';
    const tieEntries = [];
    for (let n = 0; n < 23; n++) {
        const entry = randomUUID();
        await t.save(D, entry, { title: `Tie ${n}`, providerId: `OL${5000 + n}W`, data: reading({ status: 'currently-reading' }) });
        tieEntries.push(entry);
    }
    await asAdmin(db);
    for (const entry of tieEntries) {
        await db.query(`insert into public.textual_activity(actor_id, transition_id, kind, book_id, entry_id, read_number, eligible, occurred_at, published_at)
            select $1, gen_random_uuid(), 'started', e.book_id, e.id, 1, true, $3, $3 from public.textual_library_entries e where e.user_id = $1 and e.id = $2`, [D, entry, tie]);
    }
    const all = await t.allFeed(A, 7);
    const ids = all.map(e => e.id);
    eq(new Set(ids).size, ids.length, 'no duplicate events across pages');
    eq(all.filter(e => e.actor.username === 'dot_com').length, 23, 'identical timestamps never drop events');
    const resorted = [...all].sort((x, y) => (x.published_at === y.published_at ? (x.id < y.id ? 1 : -1) : (x.published_at < y.published_at ? 1 : -1)));
    eq(ids, resorted.map(e => e.id), 'order is published_at, id descending');
    // New events after the session cutoff stay out of later pages; deletions don't duplicate.
    const firstPage = await t.feed(A, { limit: 5 });
    await t.save(D, randomUUID(), { title: 'Brand new', providerId: 'OL5100W', data: reading({ status: 'currently-reading' }), activity: [await intent(t, D, 'started')] });
    await t.save(D, tieEntries[22], { title: 'Tie 22', providerId: 'OL5022W', data: reading({ status: 'currently-reading' }), deleted: true });
    const rest = []; let cursor = firstPage.next;
    while (cursor) { const page = await t.feed(A, { cutoff: firstPage.cutoff, before: cursor, limit: 5 }); rest.push(...page.events); cursor = page.next; }
    ok(!rest.some(e => e.book.title === 'Brand new'), 'events published after the cutoff wait for a refresh');
    eq(new Set([...firstPage.events, ...rest].map(e => e.id)).size, firstPage.events.length + rest.length, 'concurrent changes cause no duplicates');
    ok((await t.feed(A)).events.some(e => e.book.title === 'Brand new'), 'a refreshed first page includes new events');

    // ---------------- Discover → Friends ----------------
    // A: friends with B and D. C: unrelated. A owns Book 05 (in B's archive) to test exclusion.
    await t.save(A, randomUUID(), { title: 'Already mine', providerId: 'OL2001W', data: reading({ status: 'read' }) });
    await t.publish(D, 1, card([favorite(randomUUID(), 3002, 'Emma'), favorite(randomUUID(), 2001, 'Persuasion')]));
    await t.publish(C, 0, card([favorite(randomUUID(), 1001, 'Stranger shelf')]));
    let discovered = await t.allDiscovery(A, 2);
    const titles = discovered.books.map(b => b.title);
    ok(discovered.hasFriends, 'the response says whether friends exist');
    ok(titles.includes('Emma'), 'shared shelves and activity contribute');
    ok(!titles.includes('Persuasion') && !titles.includes('Already mine'), 'books already in the viewer’s archive are excluded');
    ok(!titles.includes('Stranger shelf'), 'non-friends never contribute');
    eq(new Set(discovered.books.map(b => b.book_id)).size, discovered.books.length, 'discovery pages never repeat a book');
    eq(titles[0], 'Emma', 'books from several friends rank first');
    captured.discovery_page = await t.discovery(A, { limit: 2 });
    ok(discovered.books.every(b => Array.isArray(b.sources)), 'every book carries its contribution sources');
    // Private ratings never rank; shared high ratings do.
    const tieBook = await t.bookID('openlibrary', 'OL5001W');
    await t.review(D, tieBook, 0, reviewContent({ rating: 20 }));
    ok(!(await t.allDiscovery(A)).books.find(b => b.title === 'Tie 1')?.sources.includes('review'), 'a private five-star review contributes nothing');
    await t.review(D, tieBook, 1, reviewContent({ rating: 20, visibility: 'public' }), { activity: [await intent(t, D, 'review')] });
    ok((await t.allDiscovery(A)).books.find(b => b.title === 'Tie 1').sources.includes('review'), 'a shared high rating contributes');
    // Sharing off removes activity contributions, keeps curated shelves.
    await t.setSettings(D, { activitySharing: false });
    discovered = await t.allDiscovery(A);
    ok(!discovered.books.some(b => b.title.startsWith('Tie')), 'sharing off removes activity-derived books');
    ok(discovered.books.some(b => b.title === 'Emma'), 'curated shelves remain independently public');
    await t.setSettings(D, { activitySharing: true });
    // Friendship removal removes that friend's contributions only.
    await as(db, A);
    const adFriend = (await t.one('select public.textual_list_friends() r')).friends.find(f => f.username === 'dot_com');
    await t.friendship(A, 'remove', D, adFriend.relationship.request_id);
    discovered = await t.allDiscovery(A);
    ok(!discovered.books.some(b => b.title.startsWith('Tie')), 'an unfriended reader no longer contributes');
    ok(discovered.books.some(b => b.title === 'Emma'), 'a book stays when another friend independently contributes it');
    eq((await t.allDiscovery(C)).books, [], 'no friends, no books (and nothing invented)');
    eq((await t.allDiscovery(C)).hasFriends, false, 'the empty state can route to Community');

    // ---------------- Wire contract with the iOS client ----------------
    {
        const F = await t.user(6, 'contract_reader', 'Fern');
        const change = contract.client.library_change;
        const synced = await t.sync(F, [change]);
        eq(synced.results[0].status, 'applied', 'the app’s exact library payload is accepted');
        eq((await t.activityRows(F)).map(r => [r.kind, r.eligible]), [['started', true], ['quote', true]],
            'the app’s intents (uppercase UUIDs, ISO timestamps) verify and publish');
        const shelfIntent = contract.client.shelf_intent;
        const shelfCard = card([{ id: shelfIntent.favorite_id, title: 'Contract', author: 'Writer', isbn: '', coverURL: '', catalogID: 'openlibrary:OL9001W' }]);
        await t.publish(F, 0, shelfCard, [shelfIntent]);
        eq((await t.activityRows(F)).map(r => r.kind), ['started', 'quote', 'shelf'], 'the app’s shelf intent publishes with the card');
        eq((await t.setSettings(F, contract.client.settings_change)).activitySharing, false, 'the app’s settings change is accepted');
        if (process.env.WRITE_CONTRACT === '1') {
            await writeFile(contractPath, JSON.stringify({ ...contract, server: captured }, null, 2) + '\n');
        } else {
            for (const [name, example] of Object.entries(contract.server ?? {})) {
                eq(shape(captured[name]), shape(example), `server response shape unchanged: ${name}`);
            }
            ok(Object.keys(contract.server ?? {}).length >= 9, 'the contract covers every client-decoded response');
        }
    }

    // ---------------- Signed-out callers and grants ----------------
    const exposed = ['textual_social_settings', 'textual_update_social_settings', 'textual_search_readers', 'textual_update_friendship',
        'textual_list_friends', 'textual_read_public_profile', 'textual_read_profile_books', 'textual_read_feed', 'textual_read_friend_discovery',
        'textual_read_profile_friends', 'textual_publish_profile_genres', 'textual_read_profile_genre_books'];
    const signedOutCalls = [
        ['select public.textual_social_settings()', []],
        ['select public.textual_update_social_settings($1, $2::jsonb)', [A, '{}']],
        ['select public.textual_search_readers($1)', ['ada']],
        ['select public.textual_update_friendship($1, $2, $3, $4)', [A, randomUUID(), 'send', C]],
        ['select public.textual_list_friends()', []],
        ['select public.textual_read_public_profile($1)', ['bea']],
        ['select public.textual_read_profile_books($1, $2)', ['bea', 'read']],
        ['select public.textual_read_profile_friends($1)', ['bea']],
        ['select public.textual_publish_profile_genres($1, $2::jsonb)', [A, '[]']],
        ['select public.textual_read_profile_genre_books($1, $2)', ['bea', 'Fantasy']],
        ['select public.textual_read_feed()', []],
        ['select public.textual_read_friend_discovery()', []],
        ['select public.textual_read_reader_profile($1)', ['bea']],
    ];
    await as(db, null);
    for (const [sql, params] of signedOutCalls) {
        await rejects(() => db.query(sql, params), '42501', `signed-out callers cannot run: ${sql}`);
    }
    await asAdmin(db);
    const privileges = (await db.query(`select p.proname, pg_catalog.has_function_privilege('anon', p.oid, 'execute') anon,
        pg_catalog.has_function_privilege('authenticated', p.oid, 'execute') authed
        from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.proname like 'textual_%'`)).rows;
    ok(privileges.every(p => !p.anon), 'no textual function is executable by signed-out callers');
    const helpers = ['textual_social_take_rate', 'textual_reader_identity', 'textual_relationship', 'textual_are_friends', 'textual_card_stats',
        'textual_record_activity', 'textual_record_entry_activity', 'textual_valid_activity_intent', 'textual_completed_count',
        'textual_reading_date', 'textual_safe_timestamptz'];
    eq(privileges.filter(p => helpers.includes(p.proname) && p.authed).map(p => p.proname), [], 'private helpers are not part of the API');
    ok(exposed.every(name => privileges.find(p => p.proname === name)?.authed), 'social RPCs are executable by signed-in readers');
    const definers = (await db.query(`select p.proname, p.proconfig from pg_catalog.pg_proc p join pg_catalog.pg_namespace n on n.oid = p.pronamespace
        where n.nspname = 'public' and p.prosecdef and p.proname like 'textual_%'`)).rows;
    ok(definers.every(p => (p.proconfig ?? []).includes('search_path=""')), 'every security definer function pins an empty search_path');
    const rls = (await db.query(`select c.relname, c.relrowsecurity from pg_catalog.pg_class c join pg_catalog.pg_namespace n on n.oid = c.relnamespace
        where n.nspname = 'public' and c.relkind = 'r' and c.relname like 'textual_%'`)).rows;
    ok(rls.every(r => r.relrowsecurity), 'RLS is enabled on every textual table');
    // Account deletion cascades through every social row.
    await db.query('delete from auth.users where id = $1', [B]);
    eq((await db.query(`select (select count(*) from public.textual_activity where actor_id = $1)::int a,
        (select count(*) from public.textual_friendships where user_low = $1 or user_high = $1)::int f,
        (select count(*) from public.textual_social_operations where user_id = $1)::int o,
        (select count(*) from public.textual_profile_genres where user_id = $1)::int g`, [B])).rows[0], { a: 0, f: 0, o: 0, g: 0 },
        'account deletion removes social rows');

    await other.end();
    await db.end();
} catch (error) {
    console.error(`Failed after ${checks} checks:`, error);
    process.exitCode = 1;
} finally {
    await cluster.stop();
}
if (!process.exitCode) console.log(`${checks} social database checks passed (disposable local PostgreSQL ${process.env.PG_VERSION_LABEL ?? ''}).`.replace(' )', ')'));
