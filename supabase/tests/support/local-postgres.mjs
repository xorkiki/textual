// Disposable local PostgreSQL for database tests. Creates a throwaway cluster with
// initdb in a temporary directory, listens only on a private Unix socket, and
// deletes everything on stop(). Never connects to Supabase or any shared database.
//
// Requires initdb and pg_ctl on PATH (for example Homebrew postgresql@18) and
// PG_MODULE pointing to an installed `pg` package entry point.
import { mkdtemp, rm, readFile } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { join } from 'node:path';
import { execFileSync } from 'node:child_process';

const pg = (await import(process.env.PG_MODULE ?? 'pg')).default;
export const root = process.env.TEXTUAL_ROOT ?? new URL('../../..', import.meta.url).pathname;

export const uid = n => `00000000-0000-0000-0000-${String(n).padStart(12, '0')}`;

// Minimal stand-ins for the Supabase objects the migrations reference.
const SUPABASE_STUBS = `
do $$ begin
  if not exists (select 1 from pg_roles where rolname = 'anon') then create role anon nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'authenticated') then create role authenticated nologin; end if;
  if not exists (select 1 from pg_roles where rolname = 'service_role') then create role service_role nologin bypassrls; end if;
end $$;
create schema auth;
create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as
  $$ select nullif(current_setting('request.jwt.claim.sub', true), '')::uuid $$;
grant usage on schema auth to anon, authenticated, service_role;
grant execute on function auth.uid() to anon, authenticated, service_role;
create schema storage;
create table storage.buckets(id text primary key, name text, public boolean, file_size_limit bigint, allowed_mime_types text[]);
create table storage.objects(id uuid primary key default gen_random_uuid(), bucket_id text, name text, owner uuid);
alter table storage.objects enable row level security;
grant usage on schema storage to anon, authenticated, service_role;
grant select, insert, update on storage.objects to authenticated;
`;

export const BASE_MIGRATIONS = ['001_textual_accounts.sql', '003_textual_profiles.sql', '004_storygraph_import.sql',
    '005_public_reader_profiles.sql', '006_reader_profile_photos.sql', '007_reader_reviews.sql',
    '008_catalog_owned_classification.sql', '009_discovery.sql', '010_discovery_service_grants.sql'];
export const SOCIAL_MIGRATIONS = ['011_social_graph.sql', '012_social_activity.sql',
    '014_profile_friends.sql', '015_profile_genre_books.sql'];

// macOS postmaster refuses to start without an explicit locale in the environment.
const PG_ENV = { ...process.env, LC_ALL: 'en_US.UTF-8', LANG: 'en_US.UTF-8' };

export async function startCluster() {
    const dir = await mkdtemp(join(tmpdir(), 'textual-pg-'));
    const data = join(dir, 'data');
    const port = 20000 + Math.floor(Math.random() * 20000);
    execFileSync('initdb', ['-D', data, '-U', 'postgres', '--auth=trust', '--no-instructions', '-E', 'UTF8',
        '--locale=en_US.UTF-8'], { stdio: 'ignore', env: PG_ENV });
    execFileSync('pg_ctl', ['-D', data, '-w', '-l', join(dir, 'log'), '-o',
        `-p ${port} -k ${dir} -c listen_addresses='' -c fsync=off -c max_connections=40`, 'start'], { stdio: 'ignore', env: PG_ENV });
    const connect = async (database = 'postgres') => {
        const client = new pg.Client({ host: dir, port, user: 'postgres', database });
        // Shutdown at the end of a failed run must not hide the original failure.
        client.on('error', () => {});
        await client.connect();
        return client;
    };
    return {
        dir, port, connect,
        async createDatabase(name) {
            const admin = await connect();
            await admin.query(`create database ${name}`);
            await admin.end();
            const client = await connect(name);
            await client.query(SUPABASE_STUBS);
            return client;
        },
        async stop() {
            try { execFileSync('pg_ctl', ['-D', data, '-m', 'fast', 'stop'], { stdio: 'ignore', env: PG_ENV }); }
            finally { await rm(dir, { recursive: true, force: true }); }
        }
    };
}

export async function applyMigrations(client, files) {
    for (const file of files) {
        await client.query(await readFile(`${root}/supabase/migrations/${file}`, 'utf8'));
    }
}

// Run as an authenticated user (or signed out with user = null) through the real
// authenticated/anon roles, so RLS and grants apply exactly as through PostgREST.
export async function as(client, user) {
    await client.query('reset role');
    await client.query(`select set_config('request.jwt.claim.sub', $1, false)`, [user ?? '']);
    await client.query(`set role ${user ? 'authenticated' : 'anon'}`);
}

export async function asAdmin(client) {
    await client.query('reset role');
    await client.query(`select set_config('request.jwt.claim.sub', '', false)`);
}
