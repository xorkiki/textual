// Disposable PostgreSQL (PGlite); never contacts live accounts.
// PGLITE_MODULE=/path/to/@electric-sql/pglite/dist/index.js TEXTUAL_ROOT="$PWD" node supabase/tests/username-availability.test.mjs
import assert from 'node:assert/strict';
import { readFile, readdir } from 'node:fs/promises';
const { PGlite } = await import(process.env.PGLITE_MODULE ?? '@electric-sql/pglite');
const root = process.env.TEXTUAL_ROOT ?? new URL('../..', import.meta.url).pathname;
const db = new PGlite();
const a = '00000000-0000-0000-0000-000000000001';
const b = '00000000-0000-0000-0000-000000000002';
const available = async name => (await db.query('select public.textual_username_available($1) as value', [name])).rows[0].value;
try {
    await db.exec(`create role anon; create role authenticated; create role service_role;
        create schema auth; create table auth.users(id uuid primary key);
        create function auth.uid() returns uuid language sql stable as
        $$select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid$$;
        grant usage on schema auth to anon, authenticated;
        grant execute on function auth.uid() to anon, authenticated;`);
    const migration = (await readdir(`${root}/supabase/migrations`)).find(x => x.endsWith('_username_availability.sql'));
    for (const file of ['003_textual_profiles.sql', migration]) {
        await db.exec(await readFile(`${root}/supabase/migrations/${file}`, 'utf8'));
    }
    await db.query('insert into auth.users values ($1), ($2)', [a, b]);
    await db.query("insert into public.textual_profiles(user_id, first_name, username) values ($1, 'Reader', 'taken_reader')", [a]);
    await db.exec('set role anon');
    for (const name of ['taken_reader', 'TAKEN_READER', ' Taken_Reader ']) assert.equal(await available(name), false);
    assert.equal(await available('new_reader'), true);
    for (const name of [null, '', 'ab', 'bad name', 'reader%', 'a'.repeat(31), 'réader']) assert.equal(await available(name), false);
    await assert.rejects(db.query('select * from public.textual_profiles'), { code: '42501' });
    await assert.rejects(db.query("select public.textual_upsert_profile($1, 'Reader', 'new_reader')", [b]), { code: '42501' });
    console.log('PASS anonymous availability, normalization, invalid inputs, and private-profile access');
    await db.exec(`set role authenticated; select set_config('request.jwt.claim.sub', '${b}', false);`);
    assert.equal(await available('taken_reader'), false);
    assert.equal((await db.query('select * from public.textual_profiles')).rows.length, 0);
    await assert.rejects(db.query("select public.textual_upsert_profile($1, 'Reader', ' TAKEN_READER ')", [b]), { code: '23505' });
    assert.equal(await available('new_reader'), true);
    await db.query("select public.textual_upsert_profile($1, 'Reader', ' NEW_READER ')", [b]);
    assert.equal(await available('new_reader'), false);
    await db.query("select set_config('request.jwt.claim.sub', $1, false)", [a]);
    await assert.rejects(db.query("select public.textual_upsert_profile($1, 'Reader', 'new_reader')", [a]), { code: '23505' });
    assert.equal((await db.query('select username from public.textual_profiles')).rows[0].username, 'taken_reader');
    console.log('PASS atomic claim rejects a name claimed after availability check and preserves existing profile');
    await db.exec(`reset role;
        insert into auth.users select ('10000000-0000-0000-0000-' || lpad(n::text, 12, '0'))::uuid from generate_series(1, 5000) n;
        insert into public.textual_profiles(user_id, first_name, username)
        select id, 'Reader', 'reader_' || right(id::text, 12) from auth.users where id::text like '10000000%';
        analyze public.textual_profiles;`);
    const plan = (await db.query("explain (format json) select 1 from public.textual_profiles where username=lower(btrim(' TAKEN_READER '))")).rows[0]['QUERY PLAN'];
    assert.match(JSON.stringify(plan), /Index (Only )?Scan/);
    assert.match(JSON.stringify(plan), /textual_profiles_username_key/);
    console.log('PASS indexed exact-name lookup with 5,002 profiles');
} finally { await db.close(); }
