-- Public-to-signed-in-readers projection. Private profiles/imports remain owner-only.
-- Apply once after 004_storygraph_import.sql.
begin;

create table public.textual_reader_profiles (
    user_id uuid primary key references public.textual_profiles(user_id) on delete cascade,
    content jsonb not null,
    revision bigint not null default 1,
    updated_at timestamptz not null default pg_catalog.clock_timestamp()
);
alter table public.textual_reader_profiles enable row level security;
revoke all on public.textual_reader_profiles from public, anon, authenticated, service_role;

-- No directory or private-table SELECT grant: visitors use exact username lookup.
create function public.textual_read_reader_profile(p_username text)
returns jsonb language sql stable security definer set search_path = ''
as $function$
    select pg_catalog.jsonb_build_object(
        'username', p.username, 'firstName', p.first_name,
        'memberSince', p.created_at, 'revision', r.revision, 'content', r.content
    )
    from public.textual_reader_profiles r
    join public.textual_profiles p on p.user_id = r.user_id
    where auth.uid() is not null and p.username = pg_catalog.lower(pg_catalog.btrim(p_username));
$function$;

create function public.textual_publish_reader_profile(
    p_expected_user_id uuid, p_expected_revision bigint, p_content jsonb
)
returns jsonb language plpgsql security definer set search_path = ''
as $function$
declare
    v_user_id uuid := auth.uid();
    v_profile public.textual_profiles%rowtype;
    v_existing public.textual_reader_profiles%rowtype;
    v_book jsonb;
    v_key text;
    v_count integer;
begin
    if v_user_id is null or p_expected_user_id is distinct from v_user_id then
        raise exception using errcode = '42501', message = 'The active account must own this card.';
    end if;
    select * into v_profile from public.textual_profiles where user_id = v_user_id for update;
    if not found then raise exception 'Complete your profile first.'; end if;
    if p_expected_revision is null or p_expected_revision < 0 then raise exception 'Invalid revision.'; end if;
    if p_content is null or pg_catalog.jsonb_typeof(p_content) <> 'object'
       or pg_catalog.octet_length(p_content::text) > 65536 then raise exception 'Invalid card.'; end if;
    if not (p_content ?& array['stats', 'sentence', 'favorites'])
       or exists (select 1 from pg_catalog.jsonb_object_keys(p_content) k where k not in ('stats', 'sentence', 'favorites')) then
        raise exception 'Only public card fields are allowed.';
    end if;
    if pg_catalog.jsonb_typeof(p_content->'sentence') <> 'string'
       or pg_catalog.char_length(p_content->>'sentence') not between 1 and 280
       or pg_catalog.jsonb_typeof(p_content->'stats') <> 'object'
       or pg_catalog.jsonb_typeof(p_content->'favorites') <> 'array' then raise exception 'Invalid card fields.'; end if;
    if not ((p_content->'stats') ?& array['reads', 'genres', 'rereads'])
       or exists (select 1 from pg_catalog.jsonb_object_keys(p_content->'stats') k where k not in ('reads', 'genres', 'rereads')) then
        raise exception 'Invalid statistics.';
    end if;
    foreach v_key in array array['reads', 'genres', 'rereads'] loop
        if pg_catalog.jsonb_typeof(p_content->'stats'->v_key) <> 'number'
           or (p_content->'stats'->>v_key) !~ '^[0-9]{1,9}$' then raise exception 'Invalid count.'; end if;
    end loop;
    v_count := pg_catalog.jsonb_array_length(p_content->'favorites');
    if v_count > 15 then raise exception 'Choose at most 15 books.'; end if;
    for v_book in select value from pg_catalog.jsonb_array_elements(p_content->'favorites') loop
        if pg_catalog.jsonb_typeof(v_book) <> 'object' then raise exception 'Invalid book.'; end if;
        if not (v_book ?& array['id', 'title', 'author', 'isbn', 'coverURL'])
           or exists (select 1 from pg_catalog.jsonb_object_keys(v_book) k where k not in ('id', 'title', 'author', 'isbn', 'coverURL', 'catalogID')) then
            raise exception 'Only public book fields are allowed.';
        end if;
        foreach v_key in array array['id', 'title', 'author', 'isbn', 'coverURL'] loop
            if pg_catalog.jsonb_typeof(v_book->v_key) <> 'string'
               or pg_catalog.char_length(v_book->>v_key) > 2048 then raise exception 'Invalid book field.'; end if;
        end loop;
        perform (v_book->>'id')::uuid;
        if pg_catalog.char_length(v_book->>'title') < 1 then raise exception 'Book title is required.'; end if;
        if (v_book ? 'catalogID') and pg_catalog.jsonb_typeof(v_book->'catalogID') not in ('null', 'string') then
            raise exception 'Invalid catalog reference.';
        end if;
        if pg_catalog.char_length(v_book->>'catalogID') > 2048 then raise exception 'Catalog reference is too long.'; end if;
        if v_book->>'coverURL' <> '' and v_book->>'coverURL' !~ '^https?://' then raise exception 'Invalid cover URL.'; end if;
    end loop;
    if (select count(distinct value->>'id') from pg_catalog.jsonb_array_elements(p_content->'favorites')) <> v_count then
        raise exception 'A book can appear only once.';
    end if;

    select * into v_existing from public.textual_reader_profiles where user_id = v_user_id;
    -- An ambiguous/retried upload is idempotent, including after an app restart.
    if found and v_existing.content = p_content then
        return public.textual_read_reader_profile(v_profile.username);
    end if;
    if coalesce(v_existing.revision, 0) <> p_expected_revision then
        raise exception using errcode = '40001', message = 'This card changed on another device.';
    end if;
    insert into public.textual_reader_profiles(user_id, content) values (v_user_id, p_content)
    on conflict (user_id) do update set content = excluded.content,
        revision = textual_reader_profiles.revision + 1, updated_at = pg_catalog.clock_timestamp();
    return public.textual_read_reader_profile(v_profile.username);
end;
$function$;

revoke all on function public.textual_read_reader_profile(text) from public, anon, authenticated, service_role;
revoke all on function public.textual_publish_reader_profile(uuid, bigint, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.textual_read_reader_profile(text) to authenticated;
grant execute on function public.textual_publish_reader_profile(uuid, bigint, jsonb) to authenticated;
comment on table public.textual_reader_profiles is 'Explicit public card and up to 15 selected covers. Does not expose private library rows, notes, emails, or import payloads.';
commit;
