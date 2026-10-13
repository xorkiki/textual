// Disposable in-memory PostgreSQL only. Never connects to Supabase or real accounts.
// Run with PGLITE_MODULE pointing to an installed @electric-sql/pglite module and,
// when the checkout path contains spaces, TEXTUAL_ROOT set to the repository root.
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const { PGlite } = await import(process.env.PGLITE_MODULE ?? '@electric-sql/pglite');
const db = new PGlite();
const root = process.env.TEXTUAL_ROOT ?? new URL('../..', import.meta.url).pathname;
await db.exec(`create role anon; create role authenticated; create role service_role bypassrls;
create schema auth; create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
grant usage on schema auth to anon,authenticated,service_role;
grant execute on function auth.uid() to anon,authenticated,service_role;
create schema vault; create table vault.decrypted_secrets(name text, decrypted_secret text);
insert into vault.decrypted_secrets values ('textual_discovery_cron_token','test-token-0123456789');`);
for (const file of ['001_textual_accounts.sql','004_storygraph_import.sql','007_reader_reviews.sql',
                    '008_catalog_owned_classification.sql','009_discovery.sql','010_discovery_service_grants.sql']) {
    await db.exec(await readFile(`${root}/supabase/migrations/${file}`,'utf8'));
}
const uid = n => `00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
let checks = 0;
async function as(role, user) {
    await db.exec('reset role');
    await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[user ?? '']);
    await db.exec(`set role ${role}`);
}
async function denied(action, why) { await assert.rejects(action, undefined, why); checks++; }
const book = (id, extra={}) => ({provider:'openlibrary', provider_id:id, title:`Title ${id}`, author:'Writer',
    isbns:['9780000000001','bad-isbn'], cover_url:`https://covers.openlibrary.org/b/id/${id.length}-L.jpg`,
    cover_width:300, cover_height:450, first_published_year:2001, published_date:null,
    subjects:['Fiction','Poetry'], work_key:`openlibrary:${id}`, popularity:12, ...extra});
const apply = c => db.query('select public.textual_apply_discovery_collection($1::jsonb) n',[JSON.stringify(c)]).then(r => r.rows[0].n);
const read = (c, offset=0, limit=200) => db.query('select public.textual_read_discovery($1,$2,$3) r',[c,offset,limit]).then(r => r.rows[0].r);

// Service-role writes. Duplicate works in one payload keep their first position.
await as('service_role');
const past = new Date(Date.now() - 3600_000).toISOString();
const future = new Date(Date.now() + 3600_000).toISOString();
assert.equal(await apply({id:'trending', kind:'trending', source:'nyt', attribution:'Data provided by The New York Times', books:[
    book('OL1W',{sources:['apple','nyt'], source_rank:1}),
    book('OL2W',{sources:['nyt'], expires_at:past, source_rank:2}),
    book('OL3W',{sources:['nyt'], expires_at:future, source_rank:3}),
    book('OL1W',{sources:['apple']}),
]}), 3); checks++;
await apply({id:'explore:poetry', kind:'explore', source:'openlibrary', facet:'poetry', books:[book('OL10W'), book('OL11W')]});
await apply({id:'explore:history', kind:'explore', source:'openlibrary', facet:'history', books:[book('OL20W'), book('OL10W')]});
await apply({id:'new_releases', kind:'new_releases', source:'openlibrary', books:[book('OL30W',{published_date:'2026-09-01'})]});

// Invalid rows reject the whole replacement and keep the previous collection.
await denied(() => apply({id:'new_releases', kind:'new_releases', source:'openlibrary',
    books:[book('OL31W',{cover_url:'https://evil.example/cover.jpg'})]}), 'untrusted cover host');
await denied(() => apply({id:'new_releases', kind:'new_releases', source:'openlibrary',
    books:[book('not-a-work')]}), 'invalid provider id');
await denied(() => apply({id:'new_releases', kind:'new_releases', source:'openlibrary',
    books:[book('OL32W',{cover_width:null})]}), 'unmeasured cover');
await denied(() => apply({id:'Bad Id', kind:'explore', source:'openlibrary', books:[]}), 'invalid collection id');

// Token check: only the Vault value is accepted, and only service_role may ask.
assert.equal((await db.query(`select public.textual_discovery_token_valid('test-token-0123456789') ok`)).rows[0].ok, true); checks++;
assert.equal((await db.query(`select public.textual_discovery_token_valid('wrong') ok`)).rows[0].ok, false); checks++;
assert.equal((await db.query(`select public.textual_discovery_token_valid(null) ok`)).rows[0].ok, false); checks++;

// A private library row on the same catalog identity stays private.
await db.exec('reset role');
await db.query(`insert into auth.users values ($1),($2)`,[uid(1),uid(2)]);
const shared = (await db.query(`select id from public.textual_books where provider='openlibrary' and provider_id='OL1W'`)).rows[0].id;
await db.query(`insert into public.textual_library_entries(user_id,id,book_id,title,author,revision,updated_at)
    values ($1,$2,$3,'My private title','Private note author',1,now())`,[uid(1),uid(500),shared]);

// Authenticated reads through the RPC only.
await as('authenticated', uid(2));
const trending = await read('trending');
assert.deepEqual(trending.books.map(b => b.provider_id), ['OL1W','OL3W']); checks++; // expired NYT row hidden
assert.deepEqual(trending.books.map(b => b.position), [0,1]); checks++;
assert.deepEqual(trending.attribution, ['Data provided by The New York Times']); checks++;
assert.deepEqual(trending.books[0].isbns, ['9780000000001']); checks++; // invalid ISBN dropped
assert.deepEqual(trending.books[0].sources, ['apple','nyt']); checks++;
assert.equal(trending.books[0].title, 'Title OL1W'); checks++; // never a library snapshot
assert.ok(!JSON.stringify(trending).includes('My private title')); checks++;
assert.ok(!JSON.stringify(trending).includes(uid(1))); checks++;
const explore = await read('explore');
assert.equal(explore.total, 3); checks++; // OL10W appears once across subjects
assert.deepEqual(new Set(explore.books.map(b => b.facet)), new Set(['poetry','history'])); checks++;
const page = await read('explore', 1, 1);
assert.equal(page.books.length, 1); checks++;
assert.equal(page.books[0].position, 1); checks++;
assert.equal((await read('new_releases')).books[0].published_date, '2026-09-01'); checks++;
await denied(() => read('explore:poetry'), 'raw subject collections are not an endpoint');
await denied(() => read('private'), 'unknown collection');
await denied(() => db.query('select * from public.textual_discovery_books'), 'no direct table reads');
await denied(() => db.query('select * from public.textual_discovery_resolutions'), 'no resolution reads');
await denied(() => apply({id:'trending', kind:'trending', source:'apple', books:[]}), 'clients cannot write');
await denied(() => db.query(`select public.textual_discovery_token_valid('x')`), 'clients cannot probe the token');

// Signed-out callers and the anon role are rejected.
await as('authenticated', null);
await denied(() => read('trending'), 'authentication required');
await as('anon', null);
await denied(() => read('trending'), 'anon cannot execute');

// Saving a discovered book through library sync reuses the shared identity.
await db.exec('reset role');
const identities = (await db.query(`select count(*)::int n from public.textual_books where provider='openlibrary' and provider_id='OL1W'`)).rows[0].n;
assert.equal(identities, 1); checks++;
// Replacing a collection removes stale entries but keeps reusable book snapshots.
await as('service_role');
await apply({id:'explore:poetry', kind:'explore', source:'openlibrary', facet:'poetry', books:[book('OL12W')]});
await as('authenticated', uid(2));
assert.deepEqual((await read('explore')).books.map(b => b.provider_id).sort(), ['OL10W','OL12W','OL20W']); checks++;
await db.exec('reset role');
assert.equal((await db.query(`select count(*)::int n from public.textual_discovery_books where work_key='openlibrary:OL11W'`)).rows[0].n, 1); checks++;

// The refresh function's direct reads work for service_role, on Discover tables only.
await as('service_role');
assert.equal((await db.query(`select count(*)::int n from public.textual_discovery_books`)).rows[0].n > 0, true); checks++;
await db.query(`insert into public.textual_discovery_resolutions(source, source_id, provider, provider_id)
    values ('apple','123','openlibrary','OL1W') on conflict (source, source_id) do update set resolved_at = now()`); checks++;
await denied(() => db.query('delete from public.textual_discovery_books'), 'service role still writes books only through the RPC');
await as('authenticated', uid(2));
await denied(() => db.query('select * from public.textual_discovery_resolutions'), 'grants did not reach clients');

// Operator health check: fresh collections are not stale; missing kinds are; clients can't call it.
await db.exec('reset role');
const health = (await db.query('select * from public.textual_discovery_health()')).rows;
assert.deepEqual(health.map(r => [r.collection, r.stale]),
    [['explore:history', false], ['explore:poetry', false], ['new_releases', false], ['trending', false]]); checks++;
assert.equal(Number(health.find(r => r.collection === 'trending').expired), 1); checks++;
await db.exec(`update public.textual_discovery_collections set refreshed_at = now() - interval '13 hours' where id = 'trending'`);
await db.exec(`delete from public.textual_discovery_collections where kind = 'new_releases'`);
const stale = (await db.query('select * from public.textual_discovery_health()')).rows;
assert.equal(stale.find(r => r.collection === 'trending').stale, true); checks++;
assert.equal(stale.find(r => r.collection === 'new_releases').stale, true, 'never refreshed'); checks++;
await as('authenticated', uid(2));
await denied(() => db.query('select * from public.textual_discovery_health()'), 'operators only');

console.log(`${checks} discovery database checks passed (isolated in-memory PostgreSQL).`);
