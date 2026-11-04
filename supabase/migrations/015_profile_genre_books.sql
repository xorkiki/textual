-- Per-book genre evidence from the owner's Stats cache. This is private data;
-- only the two RPCs below can write or read it. Publication is atomic and
-- idempotent, and each read rechecks the owner's current Genres visibility.
create table public.textual_profile_genres (
    user_id uuid not null references auth.users(id) on delete cascade,
    entry_id uuid not null,
    genres text[] not null,
    primary key (user_id, entry_id),
    foreign key (user_id, entry_id) references public.textual_library_entries(user_id, id) on delete cascade
);
alter table public.textual_profile_genres enable row level security;
revoke all on public.textual_profile_genres from public, anon, authenticated, service_role;

create function public.textual_publish_profile_genres(p_expected_user_id uuid, p_entries jsonb)
returns boolean
language plpgsql security definer set search_path = ''
as $function$
declare
    v_user uuid := auth.uid();
    v_entry jsonb;
    v_id uuid;
    v_genres text[];
    v_seen uuid[] := array[]::uuid[];
begin
    if v_user is null or p_expected_user_id is distinct from v_user then
        raise exception using errcode = '42501', message = 'Account changed before publishing genres.';
    end if;
    if p_entries is null or pg_catalog.jsonb_typeof(p_entries) <> 'array'
       or pg_catalog.jsonb_array_length(p_entries) > 3000
       or pg_catalog.octet_length(p_entries::text) > 1048576 then
        raise exception using errcode = '22023', message = 'Invalid genre list.';
    end if;

    -- Validate the complete replacement before modifying any rows.
    for v_entry in select value from pg_catalog.jsonb_array_elements(p_entries) loop
        if pg_catalog.jsonb_typeof(v_entry) <> 'object'
           or not (v_entry ?& array['entry_id', 'genres'])
           or exists (select 1 from pg_catalog.jsonb_object_keys(v_entry) k where k not in ('entry_id', 'genres'))
           or pg_catalog.jsonb_typeof(v_entry->'entry_id') <> 'string'
           or pg_catalog.jsonb_typeof(v_entry->'genres') <> 'array'
           or pg_catalog.jsonb_array_length(v_entry->'genres') > 20
           or exists (select 1 from pg_catalog.jsonb_array_elements(v_entry->'genres') g
                      where pg_catalog.jsonb_typeof(g) <> 'string'
                         or pg_catalog.char_length(g #>> '{}') not between 1 and 80
                         or (g #>> '{}') ~ '[[:cntrl:]]') then
            raise exception using errcode = '22023', message = 'Invalid genre entry.';
        end if;
        v_id := (v_entry->>'entry_id')::uuid;
        if v_id = any(v_seen) or not exists (
            select 1 from public.textual_library_entries e
             where e.user_id = v_user and e.id = v_id and e.deleted_at is null and e.completed_reads > 0) then
            raise exception using errcode = '22023', message = 'Invalid genre book.';
        end if;
        v_seen := pg_catalog.array_append(v_seen, v_id);
    end loop;

    delete from public.textual_profile_genres where user_id = v_user;
    for v_entry in select value from pg_catalog.jsonb_array_elements(p_entries) loop
        v_id := (v_entry->>'entry_id')::uuid;
        select coalesce(pg_catalog.array_agg(g #>> '{}'), array[]::text[]) into v_genres
          from pg_catalog.jsonb_array_elements(v_entry->'genres') g;
        insert into public.textual_profile_genres(user_id, entry_id, genres)
        values (v_user, v_id, v_genres);
    end loop;
    return true;
end
$function$;

create function public.textual_read_profile_genre_books(
    p_username text, p_genre text, p_after_title text default null,
    p_after_id uuid default null, p_limit integer default 30)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $function$
declare
    v_viewer uuid := auth.uid();
    v_profile public.textual_profiles%rowtype;
    v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 60);
    v_rows jsonb;
    v_count integer;
    v_total bigint;
begin
    if v_viewer is null then
        raise exception using errcode = '42501', message = 'Authentication is required.';
    end if;
    if p_genre is null or pg_catalog.char_length(p_genre) not between 1 and 80
       or (p_after_title is null) <> (p_after_id is null) then
        raise exception using errcode = '22023', message = 'Invalid genre request.';
    end if;
    select * into v_profile from public.textual_profiles
     where username = pg_catalog.lower(pg_catalog.btrim(coalesce(p_username, '')));
    if not found then
        raise exception using errcode = 'P0002', message = 'That reader couldn’t be found.';
    end if;
    if v_viewer <> v_profile.user_id and not v_profile.genres_visible then
        raise exception using errcode = '42501', message = 'This list is private.';
    end if;

    with page as (
        select e.id, e.title, e.author, e.isbn, e.cover_url, b.provider, b.provider_id,
               pg_catalog.lower(e.title) as sort_title
          from public.textual_profile_genres g
          join public.textual_library_entries e on e.user_id = g.user_id and e.id = g.entry_id
          join public.textual_books b on b.id = e.book_id
         where g.user_id = v_profile.user_id and e.deleted_at is null and e.completed_reads > 0
           and (case when p_genre = 'Unclassified' then pg_catalog.cardinality(g.genres) = 0
                     else p_genre = any(g.genres) end)
           and (p_after_title is null or (pg_catalog.lower(e.title), e.id) > (p_after_title, p_after_id))
         order by pg_catalog.lower(e.title), e.id
         limit v_limit + 1
    )
    select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
               'entry_id', pg.id, 'title', pg.title, 'author', pg.author,
               'isbn', pg.isbn, 'cover_url', pg.cover_url,
               'catalog_id', case when pg.provider = 'google' then pg.provider_id
                                  else pg.provider || ':' || pg.provider_id end,
               'source', 'genre', 'sort_title', pg.sort_title)
               order by pg.sort_title, pg.id), '[]'::jsonb), pg_catalog.count(*)
      into v_rows, v_count from page pg;

    if p_after_title is null then
        select pg_catalog.count(*) into v_total
          from public.textual_profile_genres g
          join public.textual_library_entries e on e.user_id = g.user_id and e.id = g.entry_id
         where g.user_id = v_profile.user_id and e.deleted_at is null and e.completed_reads > 0
           and (case when p_genre = 'Unclassified' then pg_catalog.cardinality(g.genres) = 0
                     else p_genre = any(g.genres) end);
    end if;

    return pg_catalog.jsonb_build_object('books', case when v_count > v_limit then v_rows - v_limit else v_rows end,
        'total', v_total, 'next', case when v_count > v_limit then pg_catalog.jsonb_build_object(
            'title', (v_rows->(v_limit - 1))->'sort_title', 'id', (v_rows->(v_limit - 1))->'entry_id') end);
end
$function$;

revoke all on function public.textual_publish_profile_genres(uuid, jsonb),
    public.textual_read_profile_genre_books(text, text, text, uuid, integer)
    from public, anon, authenticated, service_role;
grant execute on function public.textual_publish_profile_genres(uuid, jsonb),
    public.textual_read_profile_genre_books(text, text, text, uuid, integer)
    to authenticated;
