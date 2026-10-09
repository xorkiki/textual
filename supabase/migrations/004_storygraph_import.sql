-- Add owner-private StoryGraph metadata to the existing account/CAS sync protocol.
-- Additive migration: existing rows, ownership policies and grants are retained.
begin;
alter table public.textual_books drop constraint textual_books_provider_check;
alter table public.textual_books drop constraint textual_books_check;
alter table public.textual_books add constraint textual_books_provider_check
    check (provider in ('google', 'openlibrary', 'storygraph'));
alter table public.textual_books add constraint textual_books_check
    check ((provider = 'google' and provider_id ~ '^[A-Za-z0-9_-]{1,128}$')
        or (provider = 'openlibrary' and provider_id ~ '^OL[0-9]{1,20}W$')
        or (provider = 'storygraph' and provider_id ~ '^[a-f0-9]{64}$'));

create function public.textual_valid_reading_data(d jsonb) returns boolean
language plpgsql immutable set search_path = '' as $validator$
declare k text; v jsonb; period jsonb;
begin
    if pg_catalog.jsonb_typeof(d) <> 'object' or pg_catalog.octet_length(d::text) > 131072
       or d->'version' is distinct from '1'::jsonb
       or not (d ?& array['sourceKey','status','periods','format','moods','pace','tags','originalFields']) then return false; end if;
    foreach k in array array['sourceKey','status','format','pace'] loop
        if pg_catalog.jsonb_typeof(d->k) <> 'string' then return false; end if;
    end loop;
    if d->>'sourceKey' !~ '^[a-f0-9]{64}$' then return false; end if;
    foreach k in array array['dateAdded','lastDateRead'] loop
        if d ? k and pg_catalog.jsonb_typeof(d->k) not in ('string','null') then return false; end if;
    end loop;
    if d ? 'owned' and pg_catalog.jsonb_typeof(d->'owned') not in ('boolean','null') then return false; end if;
    if d ? 'readCount' and d->'readCount' <> 'null'::jsonb then
        if pg_catalog.jsonb_typeof(d->'readCount') <> 'number' or d->>'readCount' !~ '^[0-9]{1,7}$' then return false; end if;
        if (d->>'readCount')::numeric > 1000000 then return false; end if;
    end if;
    if d ? 'rating' and d->'rating' <> 'null'::jsonb then
        if pg_catalog.jsonb_typeof(d->'rating') <> 'number' then return false; end if;
        if (d->>'rating')::numeric not between 0 and 5 then return false; end if;
    end if;
    foreach k in array array['moods','tags'] loop
        if pg_catalog.jsonb_typeof(d->k) <> 'array' then return false; end if;
        for v in select value from pg_catalog.jsonb_array_elements(d->k) loop
            if pg_catalog.jsonb_typeof(v) <> 'string' then return false; end if;
        end loop;
    end loop;
    if pg_catalog.jsonb_typeof(d->'periods') <> 'array' then return false; end if;
    for period in select value from pg_catalog.jsonb_array_elements(d->'periods') loop
        if pg_catalog.jsonb_typeof(period) <> 'object' then return false; end if;
        foreach k in array array['startedOn','finishedOn'] loop
            if period ? k and pg_catalog.jsonb_typeof(period->k) not in ('string','null') then return false; end if;
        end loop;
    end loop;
    if pg_catalog.jsonb_typeof(d->'originalFields') <> 'object' then return false; end if;
    for v in select value from pg_catalog.jsonb_each(d->'originalFields') loop
        if pg_catalog.jsonb_typeof(v) <> 'string' then return false; end if;
    end loop;
    return true;
end
$validator$;
revoke all on function public.textual_valid_reading_data(jsonb) from public, anon, authenticated;
alter table public.textual_library_entries add column reading_data jsonb
    check (reading_data is null or public.textual_valid_reading_data(reading_data));
comment on column public.textual_library_entries.reading_data is
    'Owner-private imported reading history and original export fields. Never copy into shared catalog.';

create or replace function public.textual_entry_json(p_user_id uuid, p_entry_id uuid)
returns jsonb
language sql
stable
set search_path = ''
as $function$
    select pg_catalog.jsonb_build_object(
        'id', e.id, 'book_id', e.book_id, 'revision', e.revision,
        'updated_at', e.updated_at, 'deleted_at', e.deleted_at, 'reading_data', e.reading_data,
        'book', pg_catalog.jsonb_build_object(
            'id', b.id, 'provider', b.provider, 'provider_id', b.provider_id,
            'title', e.title, 'author', e.author, 'isbn', e.isbn, 'cover_url', e.cover_url
        )
    )
    from public.textual_library_entries e
    join public.textual_books b on b.id = e.book_id
    where e.user_id = p_user_id and e.id = p_entry_id
$function$;
revoke all on function public.textual_entry_json(uuid, uuid) from public, anon, authenticated;

create or replace function public.textual_sync_library(
    p_expected_user_id uuid,
    p_changes jsonb default '[]'::jsonb,
    p_since_revision bigint default 0,
    p_limit integer default 200
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_user_id uuid := auth.uid();
    v_revision bigint;
    v_change jsonb;
    v_book jsonb;
    v_operation_id uuid;
    v_entry_id uuid;
    v_expected_revision bigint;
    v_deleted boolean;
    v_provider text;
    v_provider_id text;
    v_title text;
    v_author text;
    v_isbn text;
    v_cover_url text;
    v_book_id uuid;
    v_entry public.textual_library_entries%rowtype;
    v_existing boolean;
    v_old_request jsonb;
    v_result jsonb;
    v_results jsonb := '[]'::jsonb;
    v_entries jsonb := '[]'::jsonb;
    v_next_revision bigint;
    v_has_more boolean;
    v_now timestamptz;
begin
    if v_user_id is null then
        raise exception using errcode = '42501', message = 'Authentication is required.';
    end if;
    -- Assertion only: ownership below always comes from auth.uid(). This catches
    -- a token/account change after an offline batch was prepared by the client.
    if p_expected_user_id is null or p_expected_user_id <> v_user_id then
        raise exception using errcode = '42501', message = 'Account changed before library sync. Retry for the original account.';
    end if;
    if p_changes is null or pg_catalog.jsonb_typeof(p_changes) <> 'array'
       or pg_catalog.jsonb_array_length(p_changes) > 100
       or pg_catalog.octet_length(p_changes::text) > 1048576
       or p_since_revision is null or p_since_revision < 0
       or p_limit is null or p_limit < 1 or p_limit > 500 then
        raise exception using errcode = '22023', message = 'Invalid sync batch, cursor, or page size.';
    end if;

    insert into public.textual_sync_state(user_id) values (v_user_id)
    on conflict (user_id) do nothing;
    -- Per-account transaction lock: no later revision can commit before an earlier
    -- revision for the same account. A global sequence alone cannot guarantee this.
    select s.last_revision into v_revision
    from public.textual_sync_state s where s.user_id = v_user_id for update;
    if p_since_revision > v_revision then
        raise exception using errcode = '22023', message = 'Sync cursor is ahead of this account.';
    end if;

    for v_change in select value from pg_catalog.jsonb_array_elements(p_changes)
    loop
        if pg_catalog.jsonb_typeof(v_change) <> 'object'
           or not (v_change ?& array['operation_id', 'entry_id', 'expected_revision', 'deleted', 'book'])
           or exists (select 1 from pg_catalog.jsonb_object_keys(v_change) k
               where k not in ('operation_id', 'entry_id', 'expected_revision', 'deleted', 'book', 'reading_data'))
           or pg_catalog.jsonb_typeof(v_change->'operation_id') <> 'string'
           or pg_catalog.jsonb_typeof(v_change->'entry_id') <> 'string'
           or pg_catalog.jsonb_typeof(v_change->'expected_revision') <> 'number'
           or (v_change->>'expected_revision') !~ '^[0-9]+$'
           or pg_catalog.jsonb_typeof(v_change->'deleted') <> 'boolean'
           or pg_catalog.jsonb_typeof(v_change->'book') <> 'object' then
            raise exception using errcode = '22023', message = 'Invalid library mutation.';
        end if;
        if v_change ? 'reading_data' and v_change->'reading_data' <> 'null'::jsonb then
            if not public.textual_valid_reading_data(v_change->'reading_data') then
                raise exception using errcode = '22023', message = 'Invalid private reading data.';
            end if;
        end if;
        v_operation_id := (v_change->>'operation_id')::uuid;
        v_entry_id := (v_change->>'entry_id')::uuid;
        v_expected_revision := (v_change->>'expected_revision')::bigint;
        v_deleted := (v_change->>'deleted')::boolean;

        select o.request, o.result into v_old_request, v_result
        from public.textual_sync_operations o
        where o.user_id = v_user_id and o.operation_id = v_operation_id;
        if found then
            if v_old_request <> v_change then
                raise exception using errcode = '22023', message = 'An operation ID cannot be reused for different data.';
            end if;
            v_results := v_results || pg_catalog.jsonb_build_array(v_result);
            continue;
        end if;

        v_book := v_change->'book';
        if not (v_book ?& array['provider', 'provider_id', 'title', 'author'])
           or exists (select 1 from pg_catalog.jsonb_object_keys(v_book) k
               where k not in ('provider', 'provider_id', 'title', 'author', 'isbn', 'cover_url'))
           or pg_catalog.jsonb_typeof(v_book->'provider') <> 'string'
           or pg_catalog.jsonb_typeof(v_book->'provider_id') <> 'string'
           or pg_catalog.jsonb_typeof(v_book->'title') <> 'string'
           or pg_catalog.jsonb_typeof(v_book->'author') <> 'string'
           or (v_book ? 'isbn' and pg_catalog.jsonb_typeof(v_book->'isbn') not in ('string', 'null'))
           or (v_book ? 'cover_url' and pg_catalog.jsonb_typeof(v_book->'cover_url') not in ('string', 'null')) then
            raise exception using errcode = '22023', message = 'Invalid book snapshot.';
        end if;
        v_provider := v_book->>'provider';
        v_provider_id := v_book->>'provider_id';
        v_title := pg_catalog.btrim(v_book->>'title');
        v_author := pg_catalog.btrim(v_book->>'author');
        v_isbn := nullif(pg_catalog.btrim(v_book->>'isbn'), '');
        v_cover_url := nullif(pg_catalog.btrim(v_book->>'cover_url'), '');
        if v_provider not in ('google', 'openlibrary', 'storygraph')
           or (v_provider = 'google' and v_provider_id !~ '^[A-Za-z0-9_-]{1,128}$')
           or (v_provider = 'openlibrary' and v_provider_id !~ '^OL[0-9]{1,20}W$')
           or (v_provider = 'storygraph' and v_provider_id !~ '^[a-f0-9]{64}$')
           or pg_catalog.char_length(v_title) not between 1 and 1000
           or pg_catalog.char_length(v_author) > 1000
           or (v_isbn is not null and v_isbn !~ '^([0-9]{13}|[0-9]{9}[0-9X])$')
           or (v_cover_url is not null and (pg_catalog.char_length(v_cover_url) > 2048 or
               v_cover_url !~* '^https://(books\.google\.com|books\.googleusercontent\.com|covers\.openlibrary\.org)(/|$)')) then
            raise exception using errcode = '22023', message = 'Book snapshot fields failed validation.';
        end if;

        insert into public.textual_books(provider, provider_id)
        values (v_provider, v_provider_id) on conflict (provider, provider_id) do nothing;
        select b.id into v_book_id from public.textual_books b
        where b.provider = v_provider and b.provider_id = v_provider_id;

        select e.* into v_entry from public.textual_library_entries e
        where e.user_id = v_user_id and e.id = v_entry_id;
        v_existing := found;
        if v_existing and v_entry.book_id <> v_book_id then
            raise exception using errcode = '22023', message = 'A library entry cannot change its catalog identity.';
        end if;
        if not v_existing then
            select e.* into v_entry from public.textual_library_entries e
            where e.user_id = v_user_id and e.book_id = v_book_id;
            v_existing := found;
        end if;

        if v_existing and (v_entry.id <> v_entry_id or v_entry.revision <> v_expected_revision) then
            v_result := pg_catalog.jsonb_build_object(
                'operation_id', v_operation_id, 'status', 'conflict',
                'entry', public.textual_entry_json(v_user_id, v_entry.id));
        else
            if not v_existing and v_expected_revision <> 0 then
                raise exception using errcode = '22023', message = 'Unknown entry has a nonzero expected revision.';
            end if;
            v_revision := v_revision + 1;
            v_now := pg_catalog.clock_timestamp();
            insert into public.textual_library_entries(
                user_id, id, book_id, title, author, isbn, cover_url,
                revision, updated_at, deleted_at, reading_data
            ) values (
                v_user_id, v_entry_id, v_book_id, v_title, v_author, v_isbn, v_cover_url,
                v_revision, v_now, case when v_deleted then v_now else null end,
                case when v_change ? 'reading_data' then nullif(v_change->'reading_data', 'null'::jsonb) else v_entry.reading_data end
            ) on conflict (user_id, id) do update set
                title = excluded.title, author = excluded.author, isbn = excluded.isbn,
                cover_url = excluded.cover_url, revision = excluded.revision,
                updated_at = excluded.updated_at, deleted_at = excluded.deleted_at,
                reading_data = excluded.reading_data;
            v_result := pg_catalog.jsonb_build_object(
                'operation_id', v_operation_id, 'status', 'applied',
                'entry', public.textual_entry_json(v_user_id, v_entry_id));
        end if;

        insert into public.textual_sync_operations(user_id, operation_id, request, result)
        values (v_user_id, v_operation_id, v_change, v_result);
        v_results := v_results || pg_catalog.jsonb_build_array(v_result);
    end loop;

    update public.textual_sync_state set last_revision = v_revision where user_id = v_user_id;
    select coalesce(pg_catalog.jsonb_agg(public.textual_entry_json(v_user_id, page.id) order by page.revision), '[]'::jsonb),
           coalesce(max(page.revision), p_since_revision)
    into v_entries, v_next_revision
    from (
        select e.id, e.revision from public.textual_library_entries e
        where e.user_id = v_user_id and e.revision > p_since_revision
        order by e.revision limit p_limit
    ) page;
    select exists (
        select 1 from public.textual_library_entries e
        where e.user_id = v_user_id and e.revision > v_next_revision
    ) into v_has_more;

    return pg_catalog.jsonb_build_object(
        'results', v_results, 'entries', v_entries,
        'next_revision', v_next_revision, 'has_more', v_has_more, 'current_revision', v_revision);
end
$function$;

revoke all on function public.textual_sync_library(uuid, jsonb, bigint, integer) from public, anon, authenticated;
grant execute on function public.textual_sync_library(uuid, jsonb, bigint, integer) to authenticated;


commit;
