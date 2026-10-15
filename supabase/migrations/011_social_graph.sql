-- Social graph: privacy settings, mutual friendships, reader search, and
-- permission-filtered visitor library cards. Apply once after 001-010
-- (including the public-profile setup, 005 + 006). Additive and backward compatible:
-- current app versions keep calling the same RPC names with the same parameters.
--
-- Every new table has RLS enabled and no client grant. Clients use the RPCs below,
-- which derive identity from auth.uid() and return narrow projections only.
begin;

do $preflight$
begin
    if pg_catalog.to_regclass('public.textual_profiles') is null
       or pg_catalog.to_regclass('public.textual_reader_profiles') is null
       or pg_catalog.to_regprocedure('public.textual_publish_reader_profile(uuid,bigint,jsonb)') is null
       or pg_catalog.to_regclass('public.textual_library_entries') is null
       or pg_catalog.to_regclass('public.textual_reviews') is null then
        raise exception 'Apply 001-010 (including the public-profile setup) before the social graph migration.';
    end if;
    if not exists (select 1 from pg_catalog.pg_attribute
                   where attrelid = 'public.textual_library_entries'::regclass
                     and attname = 'reading_data' and not attisdropped) then
        raise exception 'Apply 004_storygraph_import.sql before the social graph migration.';
    end if;
    if pg_catalog.to_regclass('public.textual_friendships') is not null then
        raise exception 'Social graph objects already exist. Review migration history first.';
    end if;
end
$preflight$;

-- ---------------------------------------------------------------------------
-- Owner-controlled privacy settings, kept in the existing owner-private profile row.
-- Visibility columns start false for every existing account (their read lists were
-- never public), then default to true for profiles created after this migration.
-- ---------------------------------------------------------------------------
alter table public.textual_profiles
    add column activity_sharing boolean not null default true,
    add column sharing_version bigint not null default 1 check (sharing_version > 0),
    add column books_read_visible boolean not null default false,
    add column genres_visible boolean not null default false,
    add column rereads_visible boolean not null default false,
    add column privacy_updated_at timestamptz;
alter table public.textual_profiles
    alter column books_read_visible set default true,
    alter column genres_visible set default true,
    alter column rereads_visible set default true;
comment on column public.textual_profiles.sharing_version is
    'Bumped on every activity-sharing change. Activity stamped with an older version is never published.';

-- Prefix search on normalized username and first name.
create index textual_profiles_username_prefix on public.textual_profiles (username text_pattern_ops);
create index textual_profiles_first_name_prefix on public.textual_profiles (pg_catalog.lower(first_name) text_pattern_ops);

-- ---------------------------------------------------------------------------
-- Stats definitions shared with the app (ReadingStatsFilter.completedCount).
-- ---------------------------------------------------------------------------

-- StoryGraphImporter.normalizedDate: YYYY-MM-DD or YYYY/MM/DD, a real calendar date.
create function public.textual_reading_date(p_value text)
returns date
language sql immutable parallel safe set search_path = ''
as $function$
    select case
        when m is null then null
        when m[1]::integer < 1 or m[2]::integer not between 1 and 12 then null
        when m[3]::integer between 1 and pg_catalog.date_part('day',
            pg_catalog.make_date(m[1]::integer, m[2]::integer, 1) + interval '1 month - 1 day')::integer
            then pg_catalog.make_date(m[1]::integer, m[2]::integer, m[3]::integer)
    end
    from (select pg_catalog.regexp_match(
        pg_catalog.replace(pg_catalog.btrim(p_value, E' \t\n\r'), '/', '-'),
        '^-*([0-9]{4})-+([0-9]{2})-+([0-9]{2})-*$') as m) parsed
$function$;

-- max(readCount, valid completed periods (or last read date), status == read);
-- zero when readCount is explicitly 0 and the book is not marked read.
create function public.textual_completed_count(p_reading jsonb)
returns integer
language sql immutable parallel safe set search_path = ''
as $function$
    select case
        when p_reading is null or pg_catalog.jsonb_typeof(p_reading) <> 'object' then 0
        when base.read_count = 0 and base.status is distinct from 'read' then 0
        else greatest(coalesce(base.read_count, 0),
            case when dates.n > 0 then dates.n
                 when public.textual_reading_date(p_reading->>'lastDateRead') is not null then 1
                 else 0 end,
            case when base.status = 'read' then 1 else 0 end)
    end
    from (select
            case when pg_catalog.jsonb_typeof(p_reading->'readCount') = 'number'
                      and (p_reading->>'readCount') ~ '^[0-9]{1,7}$'
                 then (p_reading->>'readCount')::integer end as read_count,
            case when pg_catalog.jsonb_typeof(p_reading->'status') = 'string'
                 then p_reading->>'status' end as status) base,
         (select pg_catalog.count(*)::integer as n
            from pg_catalog.jsonb_array_elements(case when pg_catalog.jsonb_typeof(p_reading->'periods') = 'array'
                                                      then p_reading->'periods' else '[]'::jsonb end) period
           where pg_catalog.jsonb_typeof(period) = 'object'
             and public.textual_reading_date(period->>'finishedOn') is not null
             and (public.textual_reading_date(period->>'startedOn') is null
                  or public.textual_reading_date(period->>'startedOn')
                     <= public.textual_reading_date(period->>'finishedOn'))) dates
$function$;

-- Computed once per write, never per read. Owner-private like the rest of the row.
-- Changing textual_completed_count later requires recomputing this column.
alter table public.textual_library_entries
    add column completed_reads integer generated always as (public.textual_completed_count(reading_data)) stored;
comment on column public.textual_library_entries.completed_reads is
    'ReadingStatsFilter.completedCount of reading_data. Derived; never written directly.';

-- Books Read / Rereads pages (title order) and card counts (index-only) for one reader.
create index textual_library_completed_by_title on public.textual_library_entries
    (user_id, pg_catalog.lower(title), id) include (completed_reads)
    where deleted_at is null and completed_reads > 0;

-- ---------------------------------------------------------------------------
-- Friendships: one authoritative row per unordered pair for its whole life.
-- 'none' rows are history only (request counters) and are never returned.
-- request_id changes with every new request, so a delayed cancel/accept/remove
-- carrying an older request ID cannot touch a later relationship.
-- ---------------------------------------------------------------------------
create table public.textual_friendships (
    user_low uuid not null references auth.users(id) on delete cascade,
    user_high uuid not null references auth.users(id) on delete cascade,
    status text not null default 'none' check (status in ('none', 'pending', 'accepted')),
    requester_id uuid,
    request_id uuid,
    version bigint not null default 0 check (version >= 0),
    requested_at timestamptz,
    accepted_at timestamptz,
    updated_at timestamptz not null default pg_catalog.clock_timestamp(),
    recent_requests smallint not null default 0 check (recent_requests >= 0),
    recent_window_start timestamptz,
    primary key (user_low, user_high),
    check (user_low < user_high),
    check ((status = 'none') = (request_id is null)),
    check ((status = 'none') = (requester_id is null)),
    check (requester_id is null or requester_id = user_low or requester_id = user_high),
    check ((status = 'accepted') = (accepted_at is not null))
);
-- The primary key serves lookups by user_low; this serves the other direction.
create index textual_friendships_by_high on public.textual_friendships (user_high, status);
create index textual_friendships_by_low on public.textual_friendships (user_low, status);

-- Idempotency ledger for friendship mutations (same protocol as library/review sync).
create table public.textual_social_operations (
    user_id uuid not null references auth.users(id) on delete cascade,
    operation_id uuid not null,
    request jsonb not null,
    response jsonb not null,
    created_at timestamptz not null default pg_catalog.clock_timestamp(),
    primary key (user_id, operation_id)
);

-- Fixed-window abuse limits: one row per account and action.
create table public.textual_social_rate_limits (
    user_id uuid not null references auth.users(id) on delete cascade,
    action text not null check (action in ('search', 'friend_request')),
    window_start timestamptz not null,
    count integer not null check (count >= 0),
    primary key (user_id, action)
);

alter table public.textual_friendships enable row level security;
alter table public.textual_social_operations enable row level security;
alter table public.textual_social_rate_limits enable row level security;
revoke all on public.textual_friendships, public.textual_social_operations,
    public.textual_social_rate_limits from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Private helpers (no client execute grant).
-- ---------------------------------------------------------------------------
create function public.textual_social_take_rate(p_user_id uuid, p_action text, p_limit integer, p_window interval)
returns void
language plpgsql security definer set search_path = ''
as $function$
declare
    v_now timestamptz := pg_catalog.clock_timestamp();
    v_count integer;
begin
    insert into public.textual_social_rate_limits as l (user_id, action, window_start, count)
    values (p_user_id, p_action, v_now, 1)
    on conflict (user_id, action) do update set
        window_start = case when l.window_start <= v_now - p_window then v_now else l.window_start end,
        count = case when l.window_start <= v_now - p_window then 1 else l.count + 1 end
    returning l.count into v_count;
    if v_count > p_limit then
        raise exception using errcode = 'PT429', message = 'Too many requests. Try again in a moment.';
    end if;
end
$function$;

-- Public identity only: never email, settings, or auth data.
create function public.textual_reader_identity(p_user_id uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $function$
    select pg_catalog.jsonb_build_object(
        'user_id', p.user_id, 'username', p.username, 'first_name', p.first_name,
        'avatar_path', case when pg_catalog.jsonb_typeof(r.content->'avatarPath') = 'string'
                            then r.content->>'avatarPath' end)
    from public.textual_profiles p
    left join public.textual_reader_profiles r on r.user_id = p.user_id
    where p.user_id = p_user_id
$function$;

-- The viewer's own relationship with one other reader.
create function public.textual_relationship(p_viewer uuid, p_other uuid)
returns jsonb
language sql stable security definer set search_path = ''
as $function$
    select coalesce((
        select pg_catalog.jsonb_build_object(
            'state', case when f.status = 'accepted' then 'friends'
                          when f.requester_id = p_viewer then 'outgoing' else 'incoming' end,
            'request_id', f.request_id, 'version', f.version,
            'requested_at', f.requested_at, 'accepted_at', f.accepted_at)
        from public.textual_friendships f
        where f.user_low = least(p_viewer, p_other) and f.user_high = greatest(p_viewer, p_other)
          and f.status <> 'none'
    ), pg_catalog.jsonb_build_object('state', 'none'))
$function$;

create function public.textual_are_friends(p_a uuid, p_b uuid)
returns boolean
language sql stable security definer set search_path = ''
as $function$
    select exists (select 1 from public.textual_friendships f
                   where f.user_low = least(p_a, p_b) and f.user_high = greatest(p_a, p_b)
                     and f.status = 'accepted')
$function$;

-- Card counts under the owner's visibility rules. Hidden values are null, never
-- zero-filled here. When rereads are hidden, Books Read counts distinct books, so
-- reads - books cannot reveal them; genre counts likewise drop to books.
create function public.textual_card_stats(p_owner uuid, p_full_access boolean)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $function$
declare
    v_profile public.textual_profiles%rowtype;
    v_content jsonb;
    v_reads bigint := 0;
    v_books bigint := 0;
    v_rereads bigint := 0;
    v_reread_books bigint := 0;
    v_show_reads boolean;
    v_show_genres boolean;
    v_show_rereads boolean;
    v_breakdown jsonb;
    v_genres integer;
begin
    select * into v_profile from public.textual_profiles where user_id = p_owner;
    if not found then return null; end if;
    v_show_reads := p_full_access or v_profile.books_read_visible;
    v_show_genres := p_full_access or v_profile.genres_visible;
    v_show_rereads := p_full_access or v_profile.rereads_visible;
    select r.content into v_content from public.textual_reader_profiles r where r.user_id = p_owner;

    if v_show_reads or v_show_rereads then
        select coalesce(pg_catalog.sum(e.completed_reads), 0), pg_catalog.count(*),
               coalesce(pg_catalog.sum(e.completed_reads - 1), 0), pg_catalog.count(*) filter (where e.completed_reads > 1)
          into v_reads, v_books, v_rereads, v_reread_books
          from public.textual_library_entries e
         where e.user_id = p_owner and e.deleted_at is null and e.completed_reads > 0;
    end if;

    if v_show_genres then
        if pg_catalog.jsonb_typeof(v_content->'genreBreakdown') = 'array' then
            select coalesce(pg_catalog.jsonb_agg(case when v_show_rereads then g
                                                      else g - 'reads' end order by o), '[]'::jsonb),
                   pg_catalog.count(*) filter (where g->>'name' <> 'Unclassified')
              into v_breakdown, v_genres
              from pg_catalog.jsonb_array_elements(v_content->'genreBreakdown') with ordinality as x(g, o);
        elsif (v_content->'stats'->>'genres') ~ '^[0-9]{1,9}$' then
            -- Published by an app version without a breakdown: count only.
            v_genres := (v_content->'stats'->>'genres')::integer;
        else
            v_genres := 0;
        end if;
    end if;

    return pg_catalog.jsonb_build_object(
        'books_read', case when v_show_reads then pg_catalog.jsonb_build_object(
            'visible', true, 'count', case when v_show_rereads then v_reads else v_books end,
            'books', v_books) else pg_catalog.jsonb_build_object('visible', false) end,
        'genres', case when v_show_genres then pg_catalog.jsonb_build_object(
            'visible', true, 'count', v_genres, 'breakdown', v_breakdown)
            else pg_catalog.jsonb_build_object('visible', false) end,
        'rereads', case when v_show_rereads then pg_catalog.jsonb_build_object(
            'visible', true, 'count', v_rereads, 'books', v_reread_books)
            else pg_catalog.jsonb_build_object('visible', false) end);
end
$function$;

revoke all on function public.textual_reading_date(text), public.textual_completed_count(jsonb),
    public.textual_social_take_rate(uuid, text, integer, interval), public.textual_reader_identity(uuid),
    public.textual_relationship(uuid, uuid), public.textual_are_friends(uuid, uuid),
    public.textual_card_stats(uuid, boolean)
    from public, anon, authenticated, service_role;

-- ---------------------------------------------------------------------------
-- Settings (owner only).
-- ---------------------------------------------------------------------------
create function public.textual_social_settings()
returns jsonb
language plpgsql stable security definer set search_path = ''
as $function$
declare
    v_user uuid := auth.uid();
    v_profile public.textual_profiles%rowtype;
begin
    if v_user is null then
        raise exception using errcode = '42501', message = 'Authentication is required.';
    end if;
    select * into v_profile from public.textual_profiles where user_id = v_user;
    if not found then
        raise exception using errcode = 'P0002', message = 'Complete your profile first.';
    end if;
    return pg_catalog.jsonb_build_object(
        'activitySharing', v_profile.activity_sharing, 'sharingVersion', v_profile.sharing_version,
        'booksReadVisible', v_profile.books_read_visible, 'genresVisible', v_profile.genres_visible,
        'rereadsVisible', v_profile.rereads_visible);
end
$function$;

create function public.textual_update_social_settings(p_expected_user_id uuid, p_settings jsonb)
returns jsonb
language plpgsql security definer set search_path = ''
as $function$
declare
    v_user uuid := auth.uid();
    v_profile public.textual_profiles%rowtype;
    v_key text;
begin
    if v_user is null or p_expected_user_id is distinct from v_user then
        raise exception using errcode = '42501', message = 'Account changed before saving privacy settings.';
    end if;
    if p_settings is null or pg_catalog.jsonb_typeof(p_settings) <> 'object'
       or exists (select 1 from pg_catalog.jsonb_object_keys(p_settings) k
                  where k not in ('activitySharing', 'booksReadVisible', 'genresVisible', 'rereadsVisible')) then
        raise exception using errcode = '22023', message = 'Invalid privacy settings.';
    end if;
    for v_key in select k from pg_catalog.jsonb_object_keys(p_settings) k loop
        if pg_catalog.jsonb_typeof(p_settings->v_key) <> 'boolean' then
            raise exception using errcode = '22023', message = 'Invalid privacy settings.';
        end if;
    end loop;
    -- Row lock: serializes with activity publication, which reads the version under share lock.
    select * into v_profile from public.textual_profiles where user_id = v_user for update;
    if not found then
        raise exception using errcode = 'P0002', message = 'Complete your profile first.';
    end if;
    update public.textual_profiles set
        activity_sharing = coalesce((p_settings->>'activitySharing')::boolean, activity_sharing),
        sharing_version = sharing_version + case
            when (p_settings->>'activitySharing')::boolean is distinct from activity_sharing
                 and p_settings ? 'activitySharing' then 1 else 0 end,
        books_read_visible = coalesce((p_settings->>'booksReadVisible')::boolean, books_read_visible),
        genres_visible = coalesce((p_settings->>'genresVisible')::boolean, genres_visible),
        rereads_visible = coalesce((p_settings->>'rereadsVisible')::boolean, rereads_visible),
        privacy_updated_at = pg_catalog.clock_timestamp()
    where user_id = v_user;
    return public.textual_social_settings();
end
$function$;

-- ---------------------------------------------------------------------------
-- Reader search: normalized name/username prefixes, bounded, viewer excluded.
-- ---------------------------------------------------------------------------
create function public.textual_search_readers(
    p_query text, p_after_rank integer default null, p_after_username text default null,
    p_limit integer default 20)
returns jsonb
language plpgsql security definer set search_path = ''
as $function$
declare
    v_user uuid := auth.uid();
    v_query text := pg_catalog.lower(pg_catalog.btrim(coalesce(p_query, '')));
    v_pattern text;
    v_limit integer := least(greatest(coalesce(p_limit, 20), 1), 30);
    v_rows jsonb;
    v_count integer;
begin
    if v_user is null then
        raise exception using errcode = '42501', message = 'Authentication is required.';
    end if;
    v_query := pg_catalog.ltrim(v_query, '@');
    if pg_catalog.char_length(v_query) > 40 or (p_after_rank is null) <> (p_after_username is null)
       or (p_after_rank is not null and p_after_rank not between 0 and 2) then
        raise exception using errcode = '22023', message = 'Invalid search.';
    end if;
    if pg_catalog.char_length(v_query) < 2 then
        return pg_catalog.jsonb_build_object('results', '[]'::jsonb, 'next', null);
    end if;
    perform public.textual_social_take_rate(v_user, 'search', 60, interval '1 minute');
    v_pattern := pg_catalog.replace(pg_catalog.replace(pg_catalog.replace(v_query, '\', '\\'), '%', '\%'), '_', '\_') || '%';

    with matches as (
        select p.user_id, p.username,
               case when p.username = v_query then 0
                    when p.username like v_pattern escape '\' then 1 else 2 end as rank
          from public.textual_profiles p
         where p.user_id <> v_user
           and (p.username like v_pattern escape '\' or pg_catalog.lower(p.first_name) like v_pattern escape '\')
    ), page as (
        select m.* from matches m
         where p_after_rank is null or (m.rank, m.username) > (p_after_rank, p_after_username)
         order by m.rank, m.username
         limit v_limit + 1
    )
    select coalesce(pg_catalog.jsonb_agg(public.textual_reader_identity(pg.user_id)
                || pg_catalog.jsonb_build_object('rank', pg.rank,
                       'relationship', public.textual_relationship(v_user, pg.user_id))
                order by pg.rank, pg.username), '[]'::jsonb),
           pg_catalog.count(*)
      into v_rows, v_count
      from page pg;

    return pg_catalog.jsonb_build_object(
        'results', case when v_count > v_limit then v_rows - v_limit else v_rows end,
        'next', case when v_count > v_limit then pg_catalog.jsonb_build_object(
            'rank', (v_rows->(v_limit - 1))->'rank', 'username', (v_rows->(v_limit - 1))->'username') end);
end
$function$;

-- ---------------------------------------------------------------------------
-- Friendship state machine. Ownership comes from auth.uid(); the target only
-- selects the pair. The pair row lock serializes concurrent sends, accepts,
-- cancels, and removals; the ledger makes retries return the original outcome.
-- ---------------------------------------------------------------------------
create function public.textual_update_friendship(
    p_expected_user_id uuid, p_operation_id uuid, p_action text, p_target uuid,
    p_request_id uuid default null)
returns jsonb
language plpgsql security definer set search_path = ''
as $function$
declare
    v_user uuid := auth.uid();
    v_low uuid;
    v_high uuid;
    v_row public.textual_friendships%rowtype;
    v_request jsonb;
    v_prior jsonb;
    v_answer jsonb;
    v_outcome text;
    v_now timestamptz := pg_catalog.clock_timestamp();
    v_window_start timestamptz;
    v_recent smallint;
begin
    if v_user is null or p_expected_user_id is distinct from v_user then
        raise exception using errcode = '42501', message = 'Account changed before updating this friendship.';
    end if;
    if p_operation_id is null or p_target is null
       or p_action is null or p_action not in ('send', 'accept', 'decline', 'cancel', 'remove')
       or (p_action <> 'send' and p_request_id is null) then
        raise exception using errcode = '22023', message = 'Invalid friendship request.';
    end if;
    if p_target = v_user then
        raise exception using errcode = '22023', message = 'You can’t add yourself as a friend.';
    end if;
    if not exists (select 1 from public.textual_profiles where user_id = v_user) then
        raise exception using errcode = 'P0002', message = 'Complete your profile first.';
    end if;
    if not exists (select 1 from public.textual_profiles where user_id = p_target) then
        raise exception using errcode = 'P0002', message = 'That reader couldn’t be found.';
    end if;

    v_low := least(v_user, p_target);
    v_high := greatest(v_user, p_target);
    insert into public.textual_friendships(user_low, user_high) values (v_low, v_high)
    on conflict (user_low, user_high) do nothing;
    select * into v_row from public.textual_friendships
     where user_low = v_low and user_high = v_high for update;

    v_request := pg_catalog.jsonb_build_object('action', p_action, 'target', p_target, 'request_id', p_request_id);
    select o.request, o.response into v_prior, v_answer from public.textual_social_operations o
     where o.user_id = v_user and o.operation_id = p_operation_id;
    if found then
        if v_prior <> v_request then
            raise exception using errcode = '22023', message = 'An operation ID cannot be reused for a different change.';
        end if;
        return v_answer || pg_catalog.jsonb_build_object('relationship', public.textual_relationship(v_user, p_target));
    end if;

    if p_action = 'send' then
        if v_row.status = 'accepted' then
            v_outcome := 'already_friends';
        elsif v_row.status = 'pending' and v_row.requester_id = v_user then
            v_outcome := 'already_requested';
        elsif v_row.status = 'pending' then
            -- Opposite requests keep one pending relationship; acceptance stays explicit.
            v_outcome := 'incoming_pending';
        else
            perform public.textual_social_take_rate(v_user, 'friend_request', 30, interval '1 hour');
            v_window_start := v_row.recent_window_start;
            v_recent := v_row.recent_requests;
            if v_window_start is null or v_window_start <= v_now - interval '7 days' then
                v_window_start := v_now;
                v_recent := 0;
            end if;
            if v_recent >= 3 then
                raise exception using errcode = 'PT429', message = 'Too many requests to this reader. Try again later.';
            end if;
            update public.textual_friendships set
                status = 'pending', requester_id = v_user, request_id = pg_catalog.gen_random_uuid(),
                version = version + 1, requested_at = v_now, accepted_at = null, updated_at = v_now,
                recent_requests = v_recent + 1, recent_window_start = v_window_start
            where user_low = v_low and user_high = v_high;
            v_outcome := 'requested';
        end if;
    elsif p_action = 'accept' then
        if v_row.status = 'pending' and v_row.requester_id = p_target and v_row.request_id = p_request_id then
            update public.textual_friendships set status = 'accepted', version = version + 1,
                accepted_at = v_now, updated_at = v_now
            where user_low = v_low and user_high = v_high;
            v_outcome := 'accepted';
        else
            v_outcome := 'stale';
        end if;
    elsif p_action = 'decline' then
        if v_row.status = 'pending' and v_row.requester_id = p_target and v_row.request_id = p_request_id then
            update public.textual_friendships set status = 'none', requester_id = null, request_id = null,
                version = version + 1, requested_at = null, updated_at = v_now
            where user_low = v_low and user_high = v_high;
            v_outcome := 'declined';
        else
            v_outcome := 'stale';
        end if;
    elsif p_action = 'cancel' then
        if v_row.status = 'pending' and v_row.requester_id = v_user and v_row.request_id = p_request_id then
            update public.textual_friendships set status = 'none', requester_id = null, request_id = null,
                version = version + 1, requested_at = null, updated_at = v_now
            where user_low = v_low and user_high = v_high;
            v_outcome := 'cancelled';
        else
            v_outcome := 'stale';
        end if;
    else -- remove
        if v_row.status = 'accepted' and v_row.request_id = p_request_id then
            update public.textual_friendships set status = 'none', requester_id = null, request_id = null,
                version = version + 1, requested_at = null, accepted_at = null, updated_at = v_now
            where user_low = v_low and user_high = v_high;
            v_outcome := 'removed';
        else
            v_outcome := 'stale';
        end if;
    end if;

    v_answer := pg_catalog.jsonb_build_object('outcome', v_outcome);
    insert into public.textual_social_operations(user_id, operation_id, request, response)
    values (v_user, p_operation_id, v_request, v_answer);
    return v_answer || pg_catalog.jsonb_build_object('relationship', public.textual_relationship(v_user, p_target));
end
$function$;

-- The viewer's friends (keyset by username) and pending requests. Never another
-- reader's graph.
create function public.textual_list_friends(p_after_username text default null, p_limit integer default 100)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $function$
declare
    v_user uuid := auth.uid();
    v_limit integer := least(greatest(coalesce(p_limit, 100), 1), 200);
    v_friends jsonb;
    v_count integer;
    v_incoming jsonb := '[]'::jsonb;
    v_outgoing jsonb := '[]'::jsonb;
begin
    if v_user is null then
        raise exception using errcode = '42501', message = 'Authentication is required.';
    end if;
    with mine as (
        select case when f.user_low = v_user then f.user_high else f.user_low end as other,
               f.status, f.requester_id, f.request_id, f.requested_at, f.accepted_at
          from public.textual_friendships f
         where f.user_low = v_user and f.status <> 'none'
        union all
        select f.user_low, f.status, f.requester_id, f.request_id, f.requested_at, f.accepted_at
          from public.textual_friendships f
         where f.user_high = v_user and f.status <> 'none'
    ), friends as (
        select m.other, p.username, m.request_id, m.accepted_at
          from mine m join public.textual_profiles p on p.user_id = m.other
         where m.status = 'accepted' and (p_after_username is null or p.username > p_after_username)
         order by p.username limit v_limit + 1
    )
    select coalesce(pg_catalog.jsonb_agg(public.textual_reader_identity(fr.other)
                || pg_catalog.jsonb_build_object('relationship', pg_catalog.jsonb_build_object(
                       'state', 'friends', 'request_id', fr.request_id, 'accepted_at', fr.accepted_at))
                order by fr.username), '[]'::jsonb), pg_catalog.count(*)
      into v_friends, v_count
      from friends fr;

    if p_after_username is null then
        select coalesce(pg_catalog.jsonb_agg(public.textual_reader_identity(r.other)
                    || pg_catalog.jsonb_build_object('relationship', pg_catalog.jsonb_build_object(
                           'state', case when r.requester_id = v_user then 'outgoing' else 'incoming' end,
                           'request_id', r.request_id, 'requested_at', r.requested_at))
                    order by r.requested_at desc, r.other) filter (where r.requester_id <> v_user), '[]'::jsonb),
               coalesce(pg_catalog.jsonb_agg(public.textual_reader_identity(r.other)
                    || pg_catalog.jsonb_build_object('relationship', pg_catalog.jsonb_build_object(
                           'state', 'outgoing', 'request_id', r.request_id, 'requested_at', r.requested_at))
                    order by r.requested_at desc, r.other) filter (where r.requester_id = v_user), '[]'::jsonb)
          into v_incoming, v_outgoing
          from (select f.* from (
                    select case when x.user_low = v_user then x.user_high else x.user_low end as other,
                           x.requester_id, x.request_id, x.requested_at
                      from public.textual_friendships x
                     where (x.user_low = v_user or x.user_high = v_user) and x.status = 'pending') f
                 order by f.requested_at desc limit 200) r;
    end if;

    return pg_catalog.jsonb_build_object(
        'friends', case when v_count > v_limit then v_friends - v_limit else v_friends end,
        'incoming', v_incoming, 'outgoing', v_outgoing,
        'next', case when v_count > v_limit then (v_friends->(v_limit - 1))->'username' end);
end
$function$;

-- ---------------------------------------------------------------------------
-- Visitor library cards and their detail lists.
-- ---------------------------------------------------------------------------
create function public.textual_read_public_profile(p_username text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $function$
declare
    v_user uuid := auth.uid();
    v_profile public.textual_profiles%rowtype;
    v_content jsonb;
    v_owner boolean;
begin
    if v_user is null then
        raise exception using errcode = '42501', message = 'Authentication is required.';
    end if;
    select * into v_profile from public.textual_profiles
     where username = pg_catalog.lower(pg_catalog.btrim(coalesce(p_username, '')));
    if not found then return null; end if;
    v_owner := v_profile.user_id = v_user;
    select r.content into v_content from public.textual_reader_profiles r where r.user_id = v_profile.user_id;
    return public.textual_reader_identity(v_profile.user_id) || pg_catalog.jsonb_build_object(
        'member_since', v_profile.created_at,
        'is_owner', v_owner,
        'sentence', case when pg_catalog.jsonb_typeof(v_content->'sentence') = 'string' then v_content->'sentence' end,
        'favorites', coalesce(v_content->'favorites', '[]'::jsonb),
        'card', public.textual_card_stats(v_profile.user_id, v_owner),
        'relationship', case when v_owner then null else public.textual_relationship(v_user, v_profile.user_id) end);
end
$function$;

create function public.textual_read_profile_books(
    p_username text, p_list text, p_after_title text default null, p_after_id uuid default null,
    p_limit integer default 30)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $function$
declare
    v_user uuid := auth.uid();
    v_profile public.textual_profiles%rowtype;
    v_owner boolean;
    v_minimum integer;
    v_limit integer := least(greatest(coalesce(p_limit, 30), 1), 60);
    v_rows jsonb;
    v_count integer;
    v_total bigint;
begin
    if v_user is null then
        raise exception using errcode = '42501', message = 'Authentication is required.';
    end if;
    if p_list is null or p_list not in ('read', 'rereads') or (p_after_title is null) <> (p_after_id is null) then
        raise exception using errcode = '22023', message = 'Invalid list request.';
    end if;
    select * into v_profile from public.textual_profiles
     where username = pg_catalog.lower(pg_catalog.btrim(coalesce(p_username, '')));
    if not found then
        raise exception using errcode = 'P0002', message = 'That reader couldn’t be found.';
    end if;
    v_owner := v_profile.user_id = v_user;
    -- Rechecked on every page: a cursor is never a permission.
    if not (v_owner or (p_list = 'read' and v_profile.books_read_visible)
                   or (p_list = 'rereads' and v_profile.rereads_visible)) then
        raise exception using errcode = '42501', message = 'This list is private.';
    end if;
    v_minimum := case when p_list = 'read' then 0 else 1 end;

    with page as (
        select e.id, e.title, e.author, e.isbn, e.cover_url, b.provider, b.provider_id,
               pg_catalog.lower(e.title) as sort_title, e.completed_reads as times
          from public.textual_library_entries e
          join public.textual_books b on b.id = e.book_id
         where e.user_id = v_profile.user_id and e.deleted_at is null
           and e.completed_reads > 0 and e.completed_reads > v_minimum
           and (p_after_title is null or (pg_catalog.lower(e.title), e.id) > (p_after_title, p_after_id))
         order by pg_catalog.lower(e.title), e.id
         limit v_limit + 1
    )
    select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                'entry_id', pg.id, 'title', pg.title, 'author', pg.author, 'isbn', pg.isbn,
                'cover_url', pg.cover_url,
                'catalog_id', case when pg.provider = 'google' then pg.provider_id
                                   else pg.provider || ':' || pg.provider_id end,
                'source', case when p_list = 'read' then 'books_read' else 'rereads' end,
                'sort_title', pg.sort_title)
                || case when p_list = 'rereads' then pg_catalog.jsonb_build_object('times_read', pg.times)
                        else '{}'::jsonb end
                order by pg.sort_title, pg.id), '[]'::jsonb), pg_catalog.count(*)
      into v_rows, v_count
      from page pg;

    if p_after_title is null then
        select pg_catalog.count(*) into v_total
          from public.textual_library_entries e
         where e.user_id = v_profile.user_id and e.deleted_at is null
           and e.completed_reads > 0 and e.completed_reads > v_minimum;
    end if;

    return pg_catalog.jsonb_build_object(
        'list', p_list,
        'books', case when v_count > v_limit then v_rows - v_limit else v_rows end,
        'total', v_total,
        'next', case when v_count > v_limit then pg_catalog.jsonb_build_object(
            'title', (v_rows->(v_limit - 1))->'sort_title', 'id', (v_rows->(v_limit - 1))->'entry_id') end);
end
$function$;

-- Existing app versions: the owner still receives the exact published card (its
-- sync compares it); everyone else receives server counts under the owner's
-- visibility, with hidden counts as 0 and no genre breakdown.
create or replace function public.textual_read_reader_profile(p_username text)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $function$
declare
    v_user uuid := auth.uid();
    v_profile public.textual_profiles%rowtype;
    v_card public.textual_reader_profiles%rowtype;
    v_content jsonb;
    v_stats jsonb;
begin
    if v_user is null then return null; end if;
    select * into v_profile from public.textual_profiles
     where username = pg_catalog.lower(pg_catalog.btrim(p_username));
    if not found then return null; end if;
    select * into v_card from public.textual_reader_profiles where user_id = v_profile.user_id;
    if not found then return null; end if;
    v_content := v_card.content;
    if v_profile.user_id <> v_user then
        v_stats := public.textual_card_stats(v_profile.user_id, false);
        v_content := (v_content - 'genreBreakdown') || pg_catalog.jsonb_build_object('stats', pg_catalog.jsonb_build_object(
            'reads', coalesce((v_stats->'books_read'->>'count')::bigint, 0),
            'genres', coalesce((v_stats->'genres'->>'count')::bigint, 0),
            'rereads', coalesce((v_stats->'rereads'->>'count')::bigint, 0)));
    end if;
    return pg_catalog.jsonb_build_object(
        'username', v_profile.username, 'firstName', v_profile.first_name,
        'memberSince', v_profile.created_at, 'revision', v_card.revision, 'content', v_content);
end
$function$;

-- Card publish (006 behavior) also accepts an optional genre breakdown computed on the
-- owner's device with the Stats code. 012 extends this with shelf activity.
create or replace function public.textual_publish_reader_profile(
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
       or exists (select 1 from pg_catalog.jsonb_object_keys(p_content) k
                  where k not in ('stats', 'sentence', 'favorites', 'avatarPath', 'genreBreakdown')) then
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
    -- Genre names and per-genre book/read counts only (computed on the owner's device).
    if p_content ? 'genreBreakdown' then
        if pg_catalog.jsonb_typeof(p_content->'genreBreakdown') <> 'array'
           or pg_catalog.jsonb_array_length(p_content->'genreBreakdown') > 100
           or exists (select 1 from pg_catalog.jsonb_array_elements(p_content->'genreBreakdown') g
                      where pg_catalog.jsonb_typeof(g) <> 'object'
                         or exists (select 1 from pg_catalog.jsonb_object_keys(g) k where k not in ('name', 'books', 'reads'))
                         or not (g ?& array['name', 'books', 'reads'])
                         or pg_catalog.jsonb_typeof(g->'name') <> 'string'
                         or pg_catalog.char_length(g->>'name') not between 1 and 80
                         or (g->>'name') ~ '[[:cntrl:]]'
                         or pg_catalog.jsonb_typeof(g->'books') <> 'number' or (g->>'books') !~ '^[0-9]{1,9}$'
                         or pg_catalog.jsonb_typeof(g->'reads') <> 'number' or (g->>'reads') !~ '^[0-9]{1,9}$'
                         or (g->>'reads')::bigint < (g->>'books')::bigint)
           or (select pg_catalog.count(distinct g->>'name') from pg_catalog.jsonb_array_elements(p_content->'genreBreakdown') g)
              <> pg_catalog.jsonb_array_length(p_content->'genreBreakdown') then
            raise exception 'Invalid genre breakdown.';
        end if;
    end if;
    if p_content ? 'avatarPath' and p_content->'avatarPath' <> 'null'::jsonb then
        if pg_catalog.jsonb_typeof(p_content->'avatarPath') <> 'string'
           or (p_content->>'avatarPath') !~ ('^' || v_user_id::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$') then
            raise exception 'The photo must belong to this reader.';
        end if;
        if not exists (select 1 from storage.objects where bucket_id = 'textual-avatars' and name = p_content->>'avatarPath') then
            raise exception 'Upload the photo before publishing it.';
        end if;
    end if;
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

revoke all on function public.textual_social_settings(), public.textual_update_social_settings(uuid, jsonb),
    public.textual_search_readers(text, integer, text, integer),
    public.textual_update_friendship(uuid, uuid, text, uuid, uuid),
    public.textual_list_friends(text, integer), public.textual_read_public_profile(text),
    public.textual_read_profile_books(text, text, text, uuid, integer),
    public.textual_read_reader_profile(text), public.textual_publish_reader_profile(uuid, bigint, jsonb)
    from public, anon, authenticated, service_role;
grant execute on function public.textual_social_settings(), public.textual_update_social_settings(uuid, jsonb),
    public.textual_search_readers(text, integer, text, integer),
    public.textual_update_friendship(uuid, uuid, text, uuid, uuid),
    public.textual_list_friends(text, integer), public.textual_read_public_profile(text),
    public.textual_read_profile_books(text, text, text, uuid, integer),
    public.textual_read_reader_profile(text), public.textual_publish_reader_profile(uuid, bigint, jsonb)
    to authenticated;

comment on table public.textual_friendships is 'One row per unordered reader pair. Mutations only through textual_update_friendship.';
comment on table public.textual_social_operations is 'Friendship idempotency ledger. Do not prune without a retry-expiry protocol.';
comment on function public.textual_read_profile_books(text, text, text, uuid, integer) is 'Books read / rereads for a visible card. Permission rechecked on every page.';

commit;
