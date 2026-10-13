-- Discover (The Archive): shared, externally sourced discovery collections.
-- Apply after 001 and 007. Additive: no existing table, policy, or function changes.
--
-- Every row here comes from public catalog/chart providers through the trusted
-- `discovery-refresh` Edge Function (service role). Nothing is derived from any
-- reader's private archive, ratings, reviews, or profile, so the read endpoint
-- cannot reveal private library data. Personalized For You ranking runs on the
-- device from the reader's own local archive and is not stored here.
begin;

do $preflight$
begin
    if pg_catalog.to_regclass('public.textual_books') is null then
        raise exception 'Apply 001_textual_accounts.sql before the discovery migration.';
    end if;
    if pg_catalog.to_regclass('public.textual_discovery_books') is not null then
        raise exception 'Discovery schema already exists. Review its migration history first.';
    end if;
end
$preflight$;

-- Catalog snapshot for discovery only. Identity is the shared textual_books row
-- (Open Library work, else Google volume), so saving a discovered book resolves to
-- the same catalog ID the library sync already uses.
create table public.textual_discovery_books (
    book_id uuid primary key references public.textual_books(id),
    title text not null check (pg_catalog.char_length(title) between 1 and 500),
    author text not null check (pg_catalog.char_length(author) between 1 and 500),
    isbns text[] not null default '{}' check (pg_catalog.cardinality(isbns) <= 20),
    cover_url text not null check (pg_catalog.char_length(cover_url) <= 2048 and
        cover_url ~* '^https://(books\.google\.com|books\.googleusercontent\.com|covers\.openlibrary\.org)/'),
    -- Measured from the image itself, so the grid can reserve exact heights.
    cover_width integer not null check (cover_width between 40 and 10000),
    cover_height integer not null check (cover_height between 40 and 10000),
    first_published_year integer check (first_published_year between -3000 and 2100),
    published_date date,
    subjects text[] not null default '{}' check (pg_catalog.cardinality(subjects) <= 30),
    -- Edition/work dedupe key: provider work ID, never a fuzzy title match.
    work_key text not null check (pg_catalog.char_length(work_key) between 1 and 200),
    popularity integer not null default 0 check (popularity >= 0),
    refreshed_at timestamptz not null default pg_catalog.clock_timestamp()
);
create index textual_discovery_books_work on public.textual_discovery_books(work_key);

create table public.textual_discovery_collections (
    id text primary key check (id ~ '^[a-z][a-z0-9:_-]{0,63}$'),
    kind text not null check (kind in ('trending', 'new_releases', 'explore', 'source')),
    source text not null check (source in ('apple', 'nyt', 'openlibrary', 'textual')),
    -- Internal facet for Explore diversity (subject/era/origin); never displayed.
    facet text check (pg_catalog.char_length(facet) <= 64),
    source_date date,
    refreshed_at timestamptz not null,
    -- Provider caching limits (NYT: 24 hours) are enforced on read.
    expires_at timestamptz,
    attribution text check (pg_catalog.char_length(attribution) <= 200)
);

create table public.textual_discovery_entries (
    collection_id text not null references public.textual_discovery_collections(id) on delete cascade,
    book_id uuid not null references public.textual_discovery_books(book_id) on delete cascade,
    position integer not null check (position >= 0),
    source_rank integer check (source_rank > 0),
    -- Provenance for combined collections (for example {apple,nyt}).
    sources text[] not null default '{}' check (pg_catalog.cardinality(sources) <= 8),
    expires_at timestamptz,
    primary key (collection_id, book_id),
    unique (collection_id, position)
);
create index textual_discovery_entries_book on public.textual_discovery_entries(book_id);

-- Chart entries resolve to catalog works once; repeated chart positions skip lookups.
-- A null provider_id records a verified miss, retried after a week.
create table public.textual_discovery_resolutions (
    source text not null check (source in ('apple', 'nyt')),
    source_id text not null check (pg_catalog.char_length(source_id) between 1 and 200),
    provider text check (provider in ('google', 'openlibrary')),
    provider_id text check (pg_catalog.char_length(provider_id) <= 128),
    resolved_at timestamptz not null default pg_catalog.clock_timestamp(),
    primary key (source, source_id),
    check ((provider is null) = (provider_id is null))
);

alter table public.textual_discovery_books enable row level security;
alter table public.textual_discovery_collections enable row level security;
alter table public.textual_discovery_entries enable row level security;
alter table public.textual_discovery_resolutions enable row level security;
-- No client grants or policies: readers use the RPC below; only the service-role
-- refresh function writes. Explicit revokes override Supabase default privileges.
revoke all on public.textual_discovery_books, public.textual_discovery_collections,
    public.textual_discovery_entries, public.textual_discovery_resolutions
    from public, anon, authenticated;

-- One page of a collection. 'explore' combines every explore:* subject collection.
-- Expired provider content is never returned, even if a refresh is late.
create function public.textual_read_discovery(
    p_collection text,
    p_offset integer default 0,
    p_limit integer default 200
)
returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
    v_now timestamptz := pg_catalog.clock_timestamp();
    v_limit integer := least(greatest(coalesce(p_limit, 200), 1), 500);
    v_offset integer := greatest(coalesce(p_offset, 0), 0);
    v_result jsonb;
begin
    if auth.uid() is null then
        raise exception 'Authentication required' using errcode = '42501';
    end if;
    if p_collection is null or p_collection not in ('trending', 'new_releases', 'explore') then
        raise exception 'Unknown discovery collection' using errcode = '22023';
    end if;

    with visible as (
        select e.book_id, c.id as collection_id, c.facet, c.refreshed_at,
               e.position, e.source_rank, e.sources,
               least(e.expires_at, c.expires_at) as expires_at, c.attribution
        from public.textual_discovery_entries e
        join public.textual_discovery_collections c on c.id = e.collection_id
        where (case when p_collection = 'explore'
                    then c.kind = 'explore' else c.id = p_collection end)
          and (c.expires_at is null or c.expires_at > v_now)
          and (e.expires_at is null or e.expires_at > v_now)
    ), ranked as (
        -- Explore subjects interleave by position; the client reorders by seed.
        select v.*, pg_catalog.row_number() over (
                   order by v.position, v.collection_id, v.book_id) - 1 as ordinal
        from (select distinct on (book_id) * from visible
              order by book_id, position, collection_id) v
    )
    select pg_catalog.jsonb_build_object(
        'collection', p_collection,
        'refreshed_at', (select pg_catalog.max(refreshed_at) from visible),
        'total', (select pg_catalog.count(*) from ranked),
        'attribution', coalesce((select pg_catalog.jsonb_agg(distinct attribution)
                                 from visible where attribution is not null), '[]'::jsonb),
        'books', coalesce((
            select pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                'book_id', b.book_id,
                'provider', t.provider,
                'provider_id', t.provider_id,
                'title', b.title,
                'author', b.author,
                'isbns', pg_catalog.to_jsonb(b.isbns),
                'cover_url', b.cover_url,
                'cover_width', b.cover_width,
                'cover_height', b.cover_height,
                'first_published_year', b.first_published_year,
                'published_date', b.published_date,
                'subjects', pg_catalog.to_jsonb(b.subjects),
                'work_key', b.work_key,
                'popularity', b.popularity,
                'position', r.ordinal,
                'source_rank', r.source_rank,
                'sources', pg_catalog.to_jsonb(r.sources),
                'facet', r.facet,
                'expires_at', r.expires_at
            ) order by r.ordinal)
            from (select * from ranked order by ordinal offset v_offset limit v_limit) r
            join public.textual_discovery_books b on b.book_id = r.book_id
            join public.textual_books t on t.id = b.book_id
        ), '[]'::jsonb)
    ) into v_result;
    return v_result;
end
$function$;
revoke all on function public.textual_read_discovery(text, integer, integer) from public, anon;
grant execute on function public.textual_read_discovery(text, integer, integer) to authenticated;

-- Atomic collection replacement used only by the service-role refresh function.
-- Validates every row; a malformed provider response leaves the old collection intact.
create function public.textual_apply_discovery_collection(p_collection jsonb)
returns integer
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_id text := p_collection->>'id';
    v_book jsonb;
    v_book_id uuid;
    v_count integer := 0;
    v_seen uuid[] := '{}';
begin
    if p_collection is null or pg_catalog.jsonb_typeof(p_collection->'books') <> 'array'
       or pg_catalog.jsonb_array_length(p_collection->'books') > 500 then
        raise exception 'Invalid discovery collection' using errcode = '22023';
    end if;

    insert into public.textual_discovery_collections(id, kind, source, facet, source_date,
        refreshed_at, expires_at, attribution)
    values (v_id, p_collection->>'kind', p_collection->>'source', p_collection->>'facet',
        (p_collection->>'source_date')::date, pg_catalog.clock_timestamp(),
        (p_collection->>'expires_at')::timestamptz, p_collection->>'attribution')
    on conflict (id) do update set kind = excluded.kind, source = excluded.source,
        facet = excluded.facet, source_date = excluded.source_date,
        refreshed_at = excluded.refreshed_at, expires_at = excluded.expires_at,
        attribution = excluded.attribution;

    delete from public.textual_discovery_entries where collection_id = v_id;

    for v_book in select value from pg_catalog.jsonb_array_elements(p_collection->'books') loop
        insert into public.textual_books(provider, provider_id)
        values (v_book->>'provider', v_book->>'provider_id')
        on conflict (provider, provider_id) do nothing;
        select id into strict v_book_id from public.textual_books
        where provider = v_book->>'provider' and provider_id = v_book->>'provider_id';
        -- Two chart rows can resolve to one work; keep its best position only.
        continue when v_book_id = any(v_seen);
        v_seen := v_seen || v_book_id;

        insert into public.textual_discovery_books(book_id, title, author, isbns, cover_url,
            cover_width, cover_height, first_published_year, published_date, subjects,
            work_key, popularity, refreshed_at)
        values (v_book_id, v_book->>'title', v_book->>'author',
            coalesce((select pg_catalog.array_agg(x) from pg_catalog.jsonb_array_elements_text(v_book->'isbns') x
                      where x ~ '^([0-9]{13}|[0-9]{9}[0-9X])$'), '{}'),
            v_book->>'cover_url', (v_book->>'cover_width')::integer, (v_book->>'cover_height')::integer,
            (v_book->>'first_published_year')::integer, (v_book->>'published_date')::date,
            coalesce((select pg_catalog.array_agg(x) from (
                select pg_catalog.left(x, 120) x from pg_catalog.jsonb_array_elements_text(v_book->'subjects') x limit 30) s), '{}'),
            v_book->>'work_key', greatest(coalesce((v_book->>'popularity')::integer, 0), 0),
            pg_catalog.clock_timestamp())
        on conflict (book_id) do update set title = excluded.title, author = excluded.author,
            isbns = excluded.isbns, cover_url = excluded.cover_url,
            cover_width = excluded.cover_width, cover_height = excluded.cover_height,
            first_published_year = excluded.first_published_year,
            published_date = excluded.published_date, subjects = excluded.subjects,
            work_key = excluded.work_key, popularity = excluded.popularity,
            refreshed_at = excluded.refreshed_at;

        insert into public.textual_discovery_entries(collection_id, book_id, position,
            source_rank, sources, expires_at)
        values (v_id, v_book_id, v_count, (v_book->>'source_rank')::integer,
            coalesce((select pg_catalog.array_agg(x) from pg_catalog.jsonb_array_elements_text(v_book->'sources') x
                      where x in ('apple', 'nyt', 'openlibrary')), '{}'),
            (v_book->>'expires_at')::timestamptz);
        v_count := v_count + 1;
    end loop;
    -- Unreferenced snapshots stay a month so re-entering charts skips re-measuring.
    delete from public.textual_discovery_books b
    where b.refreshed_at < pg_catalog.clock_timestamp() - interval '30 days'
      and not exists (select 1 from public.textual_discovery_entries e where e.book_id = b.book_id);
    return v_count;
end
$function$;
revoke all on function public.textual_apply_discovery_collection(jsonb) from public, anon, authenticated;
grant execute on function public.textual_apply_discovery_collection(jsonb) to service_role;

-- Scheduled-refresh caller check. The token lives in Supabase Vault (created by
-- supabase/setup_discovery_schedule.sql) and is never typed, logged, or bundled.
create function public.textual_discovery_token_valid(p_token text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
    v_expected text;
begin
    if pg_catalog.to_regclass('vault.decrypted_secrets') is null then return false; end if;
    execute 'select decrypted_secret from vault.decrypted_secrets where name = $1 limit 1'
        into v_expected using 'textual_discovery_cron_token';
    return v_expected is not null and p_token is not null
        and pg_catalog.length(p_token) = pg_catalog.length(v_expected) and p_token = v_expected;
end
$function$;
revoke all on function public.textual_discovery_token_valid(text) from public, anon, authenticated;
grant execute on function public.textual_discovery_token_valid(text) to service_role;

-- Operator check: run `select * from public.textual_discovery_health();` in the SQL
-- Editor. A collection is stale after missing two scheduled refreshes.
create function public.textual_discovery_health()
returns table (collection text, refreshed_at timestamptz, books bigint, expired bigint, stale boolean)
language sql
stable
security definer
set search_path = ''
as $function$
    with expected(kind, max_age) as (values
        ('trending', interval '12 hours'), ('new_releases', interval '48 hours'), ('explore', interval '48 hours'))
    select c.id, c.refreshed_at,
           pg_catalog.count(e.book_id),
           pg_catalog.count(e.book_id) filter (where e.expires_at <= pg_catalog.clock_timestamp()),
           c.refreshed_at < pg_catalog.clock_timestamp() - x.max_age
    from public.textual_discovery_collections c
    join expected x on x.kind = c.kind
    left join public.textual_discovery_entries e on e.collection_id = c.id
    group by c.id, c.refreshed_at, x.max_age
    union all
    -- A kind with no collection at all has never refreshed successfully.
    select x.kind, null, 0, 0, true from expected x
    where not exists (select 1 from public.textual_discovery_collections c where c.kind = x.kind)
    order by 1
$function$;
revoke all on function public.textual_discovery_health() from public, anon, authenticated;

commit;
