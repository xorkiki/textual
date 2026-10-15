-- Social activity, Community feed, and Discover → Friends. Apply once after 011.
-- Activity rows are written only inside the existing source mutations
-- (library sync, review save, card publish), in the same transaction, and only
-- for explicit app intents the server can verify against the old/new state.
-- Imports, downloads, conflict merges, edits, and older app versions write none.
begin;

do $preflight$
begin
    if pg_catalog.to_regclass('public.textual_friendships') is null
       or pg_catalog.to_regprocedure('public.textual_completed_count(jsonb)') is null then
        raise exception 'Apply 011_social_graph.sql before the social activity migration.';
    end if;
    if pg_catalog.to_regclass('public.textual_activity') is not null then
        raise exception 'Social activity objects already exist. Review migration history first.';
    end if;
end
$preflight$;

-- One row per verified action. Display content is always read from the source
-- (library entry, review, or card), so edits update in place and deletions or
-- privacy changes remove the event. eligible is fixed when the row is written.
create table public.textual_activity (
    id uuid primary key default pg_catalog.gen_random_uuid(),
    actor_id uuid not null references auth.users(id) on delete cascade,
    transition_id uuid not null,
    kind text not null check (kind in ('started', 'finished', 'quote', 'review', 'shelf')),
    book_id uuid not null references public.textual_books(id),
    entry_id uuid,
    quote_id uuid,
    review_work_id uuid,
    shelf_owner uuid references public.textual_reader_profiles(user_id) on delete cascade,
    favorite_id uuid,
    read_number integer check (read_number > 0),
    eligible boolean not null,
    occurred_at timestamptz not null,
    published_at timestamptz not null default pg_catalog.clock_timestamp(),
    unique (actor_id, transition_id),
    foreign key (actor_id, entry_id) references public.textual_library_entries(user_id, id) on delete cascade,
    foreign key (actor_id, review_work_id) references public.textual_reviews(user_id, work_id)
        on delete cascade on update cascade,
    check (case kind
        when 'started' then entry_id is not null and read_number is not null and quote_id is null
             and review_work_id is null and shelf_owner is null and favorite_id is null
        when 'finished' then entry_id is not null and read_number is not null and quote_id is null
             and review_work_id is null and shelf_owner is null and favorite_id is null
        when 'quote' then entry_id is not null and quote_id is not null and read_number is null
             and review_work_id is null and shelf_owner is null and favorite_id is null
        when 'review' then review_work_id is not null and entry_id is null and quote_id is null
             and read_number is null and shelf_owner is null and favorite_id is null
        when 'shelf' then shelf_owner = actor_id and favorite_id is not null and entry_id is null
             and quote_id is null and read_number is null and review_work_id is null
    end)
);
-- Distinct legitimate actions stay distinct (each reread has its own read number);
-- retries and duplicate intents for the same source collapse to one row.
create unique index textual_activity_one_read_event on public.textual_activity (actor_id, entry_id, kind, read_number)
    where kind in ('started', 'finished');
create unique index textual_activity_one_quote on public.textual_activity (actor_id, entry_id, quote_id) where kind = 'quote';
create unique index textual_activity_one_review on public.textual_activity (actor_id, review_work_id) where kind = 'review';
create unique index textual_activity_one_shelf on public.textual_activity (actor_id, favorite_id) where kind = 'shelf';
-- Feed and friend discovery: newest eligible events per friend.
create index textual_activity_feed on public.textual_activity (actor_id, published_at desc, id desc) where eligible;

alter table public.textual_activity enable row level security;
revoke all on public.textual_activity from public, anon, authenticated, service_role;
comment on table public.textual_activity is 'Social activity references. No copied text, ratings, notes, or images. Read only through textual_read_feed / textual_read_friend_discovery.';

-- ---------------------------------------------------------------------------
-- Private helpers.
-- ---------------------------------------------------------------------------
create function public.textual_safe_timestamptz(p_value text)
returns timestamptz
language plpgsql stable set search_path = ''
as $function$
begin
    if p_value is null or pg_catalog.char_length(p_value) > 40 then return null; end if;
    return p_value::timestamptz;
exception when others then
    return null;
end
$function$;

create function public.textual_valid_activity_intent(p_intent jsonb, p_kinds text[])
returns boolean
language sql immutable set search_path = ''
as $function$
    select p_intent is not null and pg_catalog.jsonb_typeof(p_intent) = 'object'
       and p_intent ?& array['id', 'kind', 'shared', 'sharing_version', 'occurred_at']
       and not exists (select 1 from pg_catalog.jsonb_object_keys(p_intent) k
                       where k not in ('id', 'kind', 'shared', 'sharing_version', 'occurred_at', 'quote_id', 'favorite_id'))
       and pg_catalog.jsonb_typeof(p_intent->'id') = 'string'
       and (p_intent->>'id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
       and pg_catalog.jsonb_typeof(p_intent->'kind') = 'string' and (p_intent->>'kind') = any(p_kinds)
       and pg_catalog.jsonb_typeof(p_intent->'shared') = 'boolean'
       and pg_catalog.jsonb_typeof(p_intent->'sharing_version') = 'number'
       and pg_catalog.jsonb_typeof(p_intent->'occurred_at') = 'string'
       and (not (p_intent ? 'quote_id') or (pg_catalog.jsonb_typeof(p_intent->'quote_id') = 'string'
            and (p_intent->>'quote_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
       and (not (p_intent ? 'favorite_id') or (pg_catalog.jsonb_typeof(p_intent->'favorite_id') = 'string'
            and (p_intent->>'favorite_id') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'))
$function$;

-- Eligibility is decided once, under a share lock on the actor's settings row:
-- the intent must be stamped shared with the current sharing version, and
-- sharing must be on. Any toggle bumps the version, so queued intents from before
-- a toggle (including off → on) stay ineligible forever.
create function public.textual_record_activity(
    p_actor uuid, p_intent jsonb, p_kind text, p_book_id uuid,
    p_entry_id uuid default null, p_quote_id uuid default null, p_review_work_id uuid default null,
    p_favorite_id uuid default null, p_read_number integer default null)
returns boolean
language plpgsql security definer set search_path = ''
as $function$
declare
    v_sharing boolean;
    v_version bigint;
    v_eligible boolean;
    v_now timestamptz := pg_catalog.clock_timestamp();
    v_occurred timestamptz;
begin
    select p.activity_sharing, p.sharing_version into v_sharing, v_version
      from public.textual_profiles p where p.user_id = p_actor for share;
    v_eligible := coalesce(v_sharing, false)
        and p_intent->'shared' = 'true'::jsonb
        and (p_intent->>'sharing_version') = v_version::text;
    -- Display-only; ordering and authorization use published_at.
    v_occurred := least(v_now, greatest(coalesce(public.textual_safe_timestamptz(p_intent->>'occurred_at'), v_now),
                                        v_now - interval '30 days'));
    insert into public.textual_activity(actor_id, transition_id, kind, book_id, entry_id, quote_id,
        review_work_id, shelf_owner, favorite_id, read_number, eligible, occurred_at)
    values (p_actor, (p_intent->>'id')::uuid, p_kind, p_book_id, p_entry_id, p_quote_id, p_review_work_id,
        case when p_kind = 'shelf' then p_actor end, p_favorite_id, p_read_number, v_eligible, v_occurred)
    on conflict do nothing;
    return found;
end
$function$;

-- Verifies library intents against the entry's previous and new reading data.
create function public.textual_record_entry_activity(
    p_actor uuid, p_entry_id uuid, p_book_id uuid, p_old jsonb, p_new jsonb, p_intents jsonb)
returns void
language plpgsql security definer set search_path = ''
as $function$
declare
    v_intent jsonb;
    v_old_count integer := public.textual_completed_count(p_old);
    v_new_count integer := public.textual_completed_count(p_new);
    v_next_read integer;
    v_old_status text;
    v_new_status text;
    v_quote uuid;
begin
    if p_intents is null or pg_catalog.jsonb_typeof(p_intents) <> 'array' or p_new is null then return; end if;
    v_old_status := case when pg_catalog.jsonb_typeof(p_old->'status') = 'string' then p_old->>'status' end;
    v_new_status := case when pg_catalog.jsonb_typeof(p_new->'status') = 'string' then p_new->>'status' end;
    v_next_read := v_old_count;
    for v_intent in select value from pg_catalog.jsonb_array_elements(p_intents) limit 20 loop
        continue when not public.textual_valid_activity_intent(v_intent, array['started', 'finished', 'quote']);
        if v_intent->>'kind' = 'started' then
            -- Entering currently-reading (or a start that already finished in the same change).
            if v_old_status is distinct from 'currently-reading'
               and (v_new_status = 'currently-reading' or v_new_count > v_old_count) then
                perform public.textual_record_activity(p_actor, v_intent, 'started', p_book_id,
                    p_entry_id => p_entry_id, p_read_number => v_old_count + 1);
            end if;
        elsif v_intent->>'kind' = 'finished' then
            -- Each completion takes the next read number, so rereads stay distinct.
            if v_next_read < v_new_count then
                v_next_read := v_next_read + 1;
                perform public.textual_record_activity(p_actor, v_intent, 'finished', p_book_id,
                    p_entry_id => p_entry_id, p_read_number => v_next_read);
            end if;
        elsif v_intent ? 'quote_id' then
            v_quote := (v_intent->>'quote_id')::uuid;
            if exists (select 1 from pg_catalog.jsonb_array_elements(
                           case when pg_catalog.jsonb_typeof(p_new->'journal'->'quotes') = 'array'
                                then p_new->'journal'->'quotes' else '[]'::jsonb end) q
                        where pg_catalog.lower(q->>'id') = v_quote::text)
               and not exists (select 1 from pg_catalog.jsonb_array_elements(
                           case when pg_catalog.jsonb_typeof(p_old->'journal'->'quotes') = 'array'
                                then p_old->'journal'->'quotes' else '[]'::jsonb end) q
                        where pg_catalog.lower(q->>'id') = v_quote::text) then
                perform public.textual_record_activity(p_actor, v_intent, 'quote', p_book_id,
                    p_entry_id => p_entry_id, p_quote_id => v_quote);
            end if;
        end if;
    end loop;
end
$function$;

revoke all on function public.textual_safe_timestamptz(text), public.textual_valid_activity_intent(jsonb, text[]),
    public.textual_record_activity(uuid, jsonb, text, uuid, uuid, uuid, uuid, uuid, integer),
    public.textual_record_entry_activity(uuid, uuid, uuid, jsonb, jsonb, jsonb)
    from public, anon, authenticated, service_role;

-- Settings now advertise that this database verifies activity intents. The app stamps
-- intents only after seeing this, so it never sends them to a database without 012.
create or replace function public.textual_social_settings()
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
        'rereadsVisible', v_profile.rereads_visible, 'activityEnabled', true);
end
$function$;
revoke all on function public.textual_social_settings() from public, anon, authenticated, service_role;
grant execute on function public.textual_social_settings() to authenticated;

-- ---------------------------------------------------------------------------
-- Library sync: unchanged protocol plus an optional per-change "activity" array.
-- Body copied from 004; changes are marked "social".
-- ---------------------------------------------------------------------------
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
    v_new_reading jsonb; -- social
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
               where k not in ('operation_id', 'entry_id', 'expected_revision', 'deleted', 'book', 'reading_data', 'activity'))
           or pg_catalog.jsonb_typeof(v_change->'operation_id') <> 'string'
           or pg_catalog.jsonb_typeof(v_change->'entry_id') <> 'string'
           or pg_catalog.jsonb_typeof(v_change->'expected_revision') <> 'number'
           or (v_change->>'expected_revision') !~ '^[0-9]+$'
           or pg_catalog.jsonb_typeof(v_change->'deleted') <> 'boolean'
           or pg_catalog.jsonb_typeof(v_change->'book') <> 'object' then
            raise exception using errcode = '22023', message = 'Invalid library mutation.';
        end if;
        -- social: intents are optional and bounded; malformed intents are ignored below.
        if v_change ? 'activity' and (pg_catalog.jsonb_typeof(v_change->'activity') <> 'array'
           or pg_catalog.jsonb_array_length(v_change->'activity') > 20) then
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
            v_new_reading := case when v_change ? 'reading_data' then nullif(v_change->'reading_data', 'null'::jsonb)
                                  else v_entry.reading_data end; -- social: computed once, reused below
            insert into public.textual_library_entries(
                user_id, id, book_id, title, author, isbn, cover_url,
                revision, updated_at, deleted_at, reading_data
            ) values (
                v_user_id, v_entry_id, v_book_id, v_title, v_author, v_isbn, v_cover_url,
                v_revision, v_now, case when v_deleted then v_now else null end,
                v_new_reading
            ) on conflict (user_id, id) do update set
                title = excluded.title, author = excluded.author, isbn = excluded.isbn,
                cover_url = excluded.cover_url, revision = excluded.revision,
                updated_at = excluded.updated_at, deleted_at = excluded.deleted_at,
                reading_data = excluded.reading_data;
            -- social: verified activity in the same transaction as the source change.
            if v_change ? 'activity' and not v_deleted and v_change ? 'reading_data' then
                perform public.textual_record_entry_activity(v_user_id, v_entry_id, v_book_id,
                    case when v_existing then v_entry.reading_data end, v_new_reading, v_change->'activity');
            end if;
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

revoke all on function public.textual_sync_library(uuid, jsonb, bigint, integer) from public, anon, authenticated, service_role;
grant execute on function public.textual_sync_library(uuid, jsonb, bigint, integer) to authenticated;

-- ---------------------------------------------------------------------------
-- Review save: unchanged behavior plus an optional, defaulted p_activity.
-- Body copied from 007; changes are marked "social".
-- ---------------------------------------------------------------------------
drop function public.textual_save_review(uuid, uuid, uuid, bigint, jsonb, boolean);
create function public.textual_save_review(p_expected_user_id uuid,p_operation_id uuid,
    p_book_id uuid,p_expected_revision bigint,p_content jsonb,p_deleted boolean default false,
    p_activity jsonb default null) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); w uuid; r public.textual_reviews; req jsonb; prior jsonb; answer jsonb;
    v_was_shared boolean; v_intent jsonb; -- social
begin
    if u is null or p_expected_user_id is distinct from u then
        raise exception using errcode='42501',message='Account changed.'; end if;
    if p_operation_id is null or p_book_id is null or p_expected_revision is null or p_expected_revision < 0
       or p_deleted is null or not public.textual_valid_review(p_content) then
        raise exception using errcode='22023',message='Invalid review.'; end if;
    if p_activity is not null and (jsonb_typeof(p_activity) <> 'array' or jsonb_array_length(p_activity) > 5) then
        raise exception using errcode='22023',message='Invalid review.'; end if; -- social
    -- Same lock as library sync serializes this account's durable retry ledger.
    insert into public.textual_sync_state(user_id) values(u) on conflict do nothing;
    perform 1 from public.textual_sync_state where user_id=u for update;
    req := jsonb_build_object('book',p_book_id,'revision',p_expected_revision,'content',p_content,'deleted',p_deleted);
    select request,response into prior,answer from public.textual_review_operations where user_id=u and operation_id=p_operation_id;
    if found then
        if prior <> req then raise exception using errcode='22023',message='Operation ID reused.'; end if;
        return answer;
    end if;
    select work_id into w from public.textual_review_book_links where book_id=p_book_id;
    if w is null then raise exception 'Book identity is not ready.'; end if;
    if not exists(select 1 from public.textual_library_entries where user_id=u and book_id=p_book_id and deleted_at is null)
       and not (p_deleted and exists(select 1 from public.textual_reviews where user_id=u and work_id=w)) then
        raise exception using errcode='42501',message='Sync this book to your library before reviewing.'; end if;
    perform 1 from public.textual_review_works where id=w for update;
    select * into r from public.textual_reviews where user_id=u and work_id=w;
    v_was_shared := r.user_id is not null and not r.deleted and r.content->>'visibility' = 'public'; -- social
    if coalesce(r.revision,0) <> p_expected_revision then
        answer := jsonb_build_object('status','conflict','review',case when r.user_id is null then null else public.textual_review_json(r) end);
    else
        insert into public.textual_reviews(user_id,work_id,book_id,content,revision,deleted)
        values(u,w,p_book_id,p_content,p_expected_revision+1,p_deleted)
        on conflict(user_id,work_id) do update set book_id=excluded.book_id,content=excluded.content,
            revision=excluded.revision,deleted=excluded.deleted,updated_at=clock_timestamp()
        returning * into r;
        answer := jsonb_build_object('status','applied','review',public.textual_review_json(r));
        -- social: a review becomes activity only when it enters shared visibility.
        if p_activity is not null and not p_deleted and not v_was_shared and r.content->>'visibility' = 'public' then
            for v_intent in select value from jsonb_array_elements(p_activity) loop
                if public.textual_valid_activity_intent(v_intent, array['review']) then
                    perform public.textual_record_activity(u, v_intent, 'review', p_book_id, p_review_work_id => w);
                    exit;
                end if;
            end loop;
        end if;
    end if;
    insert into public.textual_review_operations values(u,p_operation_id,req,answer);
    return answer;
end $$;
revoke all on function public.textual_save_review(uuid,uuid,uuid,bigint,jsonb,boolean,jsonb) from public,anon,authenticated,service_role;
grant execute on function public.textual_save_review(uuid,uuid,uuid,bigint,jsonb,boolean,jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Card publish: 006 behavior, plus an optional genre breakdown computed on the
-- owner's device with the Stats code, and an optional p_activity for shelf adds.
-- ---------------------------------------------------------------------------
drop function public.textual_publish_reader_profile(uuid, bigint, jsonb);
create function public.textual_publish_reader_profile(
    p_expected_user_id uuid, p_expected_revision bigint, p_content jsonb, p_activity jsonb default null
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
    v_intent jsonb;       -- social
    v_favorite jsonb;     -- social
    v_catalog text;       -- social
    v_provider text;      -- social
    v_provider_id text;   -- social
    v_book_id uuid;       -- social
begin
    if v_user_id is null or p_expected_user_id is distinct from v_user_id then
        raise exception using errcode = '42501', message = 'The active account must own this card.';
    end if;
    select * into v_profile from public.textual_profiles where user_id = v_user_id for update;
    if not found then raise exception 'Complete your profile first.'; end if;
    if p_expected_revision is null or p_expected_revision < 0 then raise exception 'Invalid revision.'; end if;
    if p_content is null or pg_catalog.jsonb_typeof(p_content) <> 'object'
       or pg_catalog.octet_length(p_content::text) > 65536 then raise exception 'Invalid card.'; end if;
    if p_activity is not null and (pg_catalog.jsonb_typeof(p_activity) <> 'array'
       or pg_catalog.jsonb_array_length(p_activity) > 20) then raise exception 'Invalid card activity.'; end if;
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
    -- social: genre names and per-genre book/read counts only.
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

    -- social: a shelf event needs a favorite that is new in this publication and
    -- an existing catalog identity. Nothing is created for a recovered shelf.
    if p_activity is not null then
        for v_intent in select value from pg_catalog.jsonb_array_elements(p_activity) loop
            continue when not public.textual_valid_activity_intent(v_intent, array['shelf'])
                or not (v_intent ? 'favorite_id');
            select f into v_favorite from pg_catalog.jsonb_array_elements(p_content->'favorites') f
             where pg_catalog.lower(f->>'id') = pg_catalog.lower(v_intent->>'favorite_id') limit 1;
            continue when v_favorite is null or exists (
                select 1 from pg_catalog.jsonb_array_elements(coalesce(v_existing.content->'favorites', '[]'::jsonb)) old
                 where pg_catalog.lower(old->>'id') = pg_catalog.lower(v_intent->>'favorite_id'));
            v_catalog := case when pg_catalog.jsonb_typeof(v_favorite->'catalogID') = 'string' then v_favorite->>'catalogID' end;
            continue when v_catalog is null;
            if v_catalog like 'openlibrary:%' then
                v_provider := 'openlibrary'; v_provider_id := pg_catalog.substr(v_catalog, 13);
            elsif v_catalog like 'storygraph:%' then
                v_provider := 'storygraph'; v_provider_id := pg_catalog.substr(v_catalog, 12);
            else
                v_provider := 'google'; v_provider_id := v_catalog;
            end if;
            select b.id into v_book_id from public.textual_books b
             where b.provider = v_provider and b.provider_id = v_provider_id;
            continue when v_book_id is null;
            perform public.textual_record_activity(v_user_id, v_intent, 'shelf', v_book_id,
                p_favorite_id => (v_intent->>'favorite_id')::uuid);
        end loop;
    end if;
    return public.textual_read_reader_profile(v_profile.username);
end;
$function$;
revoke all on function public.textual_publish_reader_profile(uuid, bigint, jsonb, jsonb) from public, anon, authenticated, service_role;
grant execute on function public.textual_publish_reader_profile(uuid, bigint, jsonb, jsonb) to authenticated;

-- ---------------------------------------------------------------------------
-- Community feed: accepted friends' eligible activity, newest first, rendered
-- from current sources. Each page re-derives friendships and sharing settings.
-- ---------------------------------------------------------------------------
create function public.textual_read_feed(
    p_cutoff timestamptz default null, p_before_published_at timestamptz default null,
    p_before_id uuid default null, p_limit integer default 25)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $function$
declare
    v_user uuid := auth.uid();
    v_now timestamptz := pg_catalog.clock_timestamp();
    v_cutoff timestamptz;
    v_limit integer := least(greatest(coalesce(p_limit, 25), 1), 50);
    v_rows jsonb;
    v_count integer;
begin
    if v_user is null then
        raise exception using errcode = '42501', message = 'Authentication is required.';
    end if;
    if (p_before_published_at is null) <> (p_before_id is null) then
        raise exception using errcode = '22023', message = 'Invalid feed cursor.';
    end if;
    v_cutoff := least(coalesce(p_cutoff, v_now), v_now);

    with sharing as (
        select p.user_id as id, p.rereads_visible
          from (select case when f.user_low = v_user then f.user_high else f.user_low end as other
                  from public.textual_friendships f
                 where (f.user_low = v_user or f.user_high = v_user) and f.status = 'accepted') fr
          join public.textual_profiles p on p.user_id = fr.other
         where p.activity_sharing
    ), page as (
        -- Per friend: newest eligible events whose source is still visible, checked with
        -- index lookups only (reading data is read for quotes alone). The page is chosen
        -- before any display content is built.
        select x.id, x.published_at, x.rereads_visible from sharing s cross join lateral (
            select a.id, a.published_at, s.rereads_visible
              from public.textual_activity a
             where a.actor_id = s.id and a.eligible and a.published_at <= v_cutoff
               and (p_before_published_at is null or (a.published_at, a.id) < (p_before_published_at, p_before_id))
               and case a.kind
                   when 'started' then exists (select 1 from public.textual_library_entries e
                        where e.user_id = a.actor_id and e.id = a.entry_id and e.deleted_at is null)
                   when 'finished' then exists (select 1 from public.textual_library_entries e
                        where e.user_id = a.actor_id and e.id = a.entry_id and e.deleted_at is null)
                   when 'quote' then exists (select 1 from public.textual_library_entries e
                        cross join lateral pg_catalog.jsonb_array_elements(
                            case when pg_catalog.jsonb_typeof(e.reading_data->'journal'->'quotes') = 'array'
                                 then e.reading_data->'journal'->'quotes' else '[]'::jsonb end) q
                        where e.user_id = a.actor_id and e.id = a.entry_id and e.deleted_at is null
                          and pg_catalog.lower(q->>'id') = a.quote_id::text)
                   when 'review' then exists (select 1 from public.textual_reviews r
                        join public.textual_library_entries e on e.user_id = r.user_id and e.book_id = r.book_id and e.deleted_at is null
                        where r.user_id = a.actor_id and r.work_id = a.review_work_id
                          and not r.deleted and not r.excluded and r.content->>'visibility' = 'public')
                   when 'shelf' then exists (select 1 from public.textual_reader_profiles rp
                        cross join lateral pg_catalog.jsonb_array_elements(
                            case when pg_catalog.jsonb_typeof(rp.content->'favorites') = 'array'
                                 then rp.content->'favorites' else '[]'::jsonb end) f
                        where rp.user_id = a.shelf_owner and pg_catalog.lower(f->>'id') = a.favorite_id::text)
                   else false end
             order by a.published_at desc, a.id desc
             limit v_limit + 1
        ) x
        order by x.published_at desc, x.id desc
        limit v_limit + 1
    ), events as (
        -- Display content for the chosen page only, read from the current sources.
        select a.id, a.kind, a.published_at, a.occurred_at,
               -- Read numbers reveal rereads, so they follow the actor's Rereads setting. The
               -- opaque read key only lets the app keep different reads in separate cards.
               case when pg.rereads_visible then a.read_number end as read_number,
               case when a.kind in ('started', 'finished')
                    then pg_catalog.md5(a.entry_id::text || ':' || a.read_number::text) end as read_key,
               public.textual_reader_identity(a.actor_id) as actor,
               case a.kind
                   when 'shelf' then pg_catalog.jsonb_build_object(
                       'book_id', a.book_id, 'title', fav.item->>'title', 'author', fav.item->>'author',
                       'isbn', fav.item->>'isbn', 'cover_url', fav.item->>'coverURL',
                       'catalog_id', fav.item->>'catalogID')
                   else pg_catalog.jsonb_build_object(
                       'book_id', a.book_id, 'title', src.title, 'author', src.author, 'isbn', src.isbn,
                       'cover_url', src.cover_url,
                       'catalog_id', case when b.provider = 'google' then b.provider_id
                                          else b.provider || ':' || b.provider_id end)
               end as book,
               case when a.kind = 'quote' then pg_catalog.jsonb_build_object(
                   'text', quote.item->>'text',
                   'page', case when pg_catalog.jsonb_typeof(quote.item->'page') = 'number' then quote.item->'page' end)
               end as quote,
               case when a.kind = 'review' then pg_catalog.jsonb_build_object(
                   'rating', r.content->'rating', 'body', r.content->'body', 'spoilers', r.content->'spoilers')
               end as review
          from page pg
          join public.textual_activity a on a.id = pg.id
          join public.textual_books b on b.id = a.book_id
          left join public.textual_reviews r on a.kind = 'review'
               and r.user_id = a.actor_id and r.work_id = a.review_work_id
          -- Two exact lookups (entry primary key, or the review's book) instead of an OR join.
          left join lateral (
              select e.title, e.author, e.isbn, e.cover_url, e.reading_data
                from public.textual_library_entries e
               where a.kind <> 'review' and e.user_id = a.actor_id and e.id = a.entry_id
              union all
              select e.title, e.author, e.isbn, e.cover_url, null::jsonb
                from public.textual_library_entries e
               where a.kind = 'review' and e.user_id = a.actor_id and e.book_id = r.book_id
          ) src on true
          left join public.textual_reader_profiles shelf on a.kind = 'shelf' and shelf.user_id = a.shelf_owner
          left join lateral (
              select q as item from pg_catalog.jsonb_array_elements(
                  case when pg_catalog.jsonb_typeof(src.reading_data->'journal'->'quotes') = 'array'
                       then src.reading_data->'journal'->'quotes' else '[]'::jsonb end) q
               where a.kind = 'quote' and pg_catalog.lower(q->>'id') = a.quote_id::text limit 1) quote on true
          left join lateral (
              select f as item from pg_catalog.jsonb_array_elements(
                  case when pg_catalog.jsonb_typeof(shelf.content->'favorites') = 'array'
                       then shelf.content->'favorites' else '[]'::jsonb end) f
               where a.kind = 'shelf' and pg_catalog.lower(f->>'id') = a.favorite_id::text limit 1) fav on true
    )
    select coalesce(pg_catalog.jsonb_agg(pg_catalog.jsonb_build_object(
                'id', ev.id, 'kind', ev.kind, 'published_at', ev.published_at, 'occurred_at', ev.occurred_at,
                'read_number', ev.read_number, 'read_key', ev.read_key, 'actor', ev.actor, 'book', ev.book,
                'quote', ev.quote, 'review', ev.review, 'source', ev.kind)
                order by ev.published_at desc, ev.id desc), '[]'::jsonb), pg_catalog.count(*)
      into v_rows, v_count
      from events ev;

    return pg_catalog.jsonb_build_object(
        'cutoff', v_cutoff,
        'events', case when v_count > v_limit then v_rows - v_limit else v_rows end,
        'next', case when v_count > v_limit then pg_catalog.jsonb_build_object(
            'published_at', (v_rows->(v_limit - 1))->'published_at', 'id', (v_rows->(v_limit - 1))->'id') end);
end
$function$;

-- ---------------------------------------------------------------------------
-- Discover → Friends: permitted contributions only, scored at the session's
-- snapshot time so pages stay stable; every page re-derives permissions.
-- ---------------------------------------------------------------------------
create function public.textual_read_friend_discovery(
    p_snapshot timestamptz default null, p_after_score numeric default null,
    p_after_book uuid default null, p_limit integer default 24)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $function$
declare
    v_user uuid := auth.uid();
    v_now timestamptz := pg_catalog.clock_timestamp();
    v_snapshot timestamptz;
    v_limit integer := least(greatest(coalesce(p_limit, 24), 1), 48);
    v_rows jsonb;
    v_count integer;
    v_friend_count integer;
begin
    if v_user is null then
        raise exception using errcode = '42501', message = 'Authentication is required.';
    end if;
    if (p_after_score is null) <> (p_after_book is null) then
        raise exception using errcode = '22023', message = 'Invalid discovery cursor.';
    end if;
    v_snapshot := least(coalesce(p_snapshot, v_now), v_now);

    select pg_catalog.count(*) into v_friend_count from public.textual_friendships f
     where (f.user_low = v_user or f.user_high = v_user) and f.status = 'accepted';

    with friends as (
        select case when f.user_low = v_user then f.user_high else f.user_low end as id
          from public.textual_friendships f
         where (f.user_low = v_user or f.user_high = v_user) and f.status = 'accepted'
    ), sharing as (
        select fr.id from friends fr join public.textual_profiles p on p.user_id = fr.id where p.activity_sharing
    ), shelf as (
        -- Deliberately public curation; independent of activity sharing.
        select fr.id as friend, b.id as book_id, 3.0::numeric as weight, 'shelf'::text as source,
               pg_catalog.jsonb_build_object('title', fav->>'title', 'author', fav->>'author',
                   'isbn', fav->>'isbn', 'cover_url', fav->>'coverURL', 'catalog_id', fav->>'catalogID') as display
          from friends fr
          join public.textual_reader_profiles rp on rp.user_id = fr.id
          cross join lateral pg_catalog.jsonb_array_elements(
              case when pg_catalog.jsonb_typeof(rp.content->'favorites') = 'array'
                   then rp.content->'favorites' else '[]'::jsonb end) fav
          join public.textual_books b
            on b.provider = case when fav->>'catalogID' like 'openlibrary:%' then 'openlibrary'
                                 when fav->>'catalogID' like 'storygraph:%' then 'storygraph' else 'google' end
           and b.provider_id = case when fav->>'catalogID' like 'openlibrary:%' then pg_catalog.substr(fav->>'catalogID', 13)
                                    when fav->>'catalogID' like 'storygraph:%' then pg_catalog.substr(fav->>'catalogID', 12)
                                    else fav->>'catalogID' end
         where pg_catalog.jsonb_typeof(fav->'catalogID') = 'string'
    ), recent as (
        -- Shared activity only; a hidden or removed source contributes nothing.
        select a.actor_id, a.book_id, a.kind, a.entry_id, a.review_work_id,
               -- 30-day half-life from the session snapshot; rounded per contribution so
               -- the sum (and therefore the keyset cursor) is exact and order-independent.
               pg_catalog.round((case a.kind when 'review' then 4.0 else 2.0 end * pg_catalog.power(0.5::float8,
                   extract(epoch from (v_snapshot - a.published_at))::float8 / 2592000.0))::numeric, 6) as weight
          from sharing s
          join public.textual_activity a on a.actor_id = s.id and a.eligible
               and a.published_at <= v_snapshot and a.published_at > v_snapshot - interval '180 days'
               and a.kind in ('started', 'finished', 'review')
    ), events as (
        select a.actor_id as friend, a.book_id, a.weight, a.kind as source,
               pg_catalog.jsonb_build_object('title', e.title, 'author', e.author, 'isbn', e.isbn, 'cover_url', e.cover_url,
                   'catalog_id', case when b.provider = 'google' then b.provider_id else b.provider || ':' || b.provider_id end) as display
          from recent a
          join public.textual_library_entries e on e.user_id = a.actor_id and e.id = a.entry_id and e.deleted_at is null
          join public.textual_books b on b.id = a.book_id
         where a.kind <> 'review'
        union all
        select a.actor_id, a.book_id, a.weight, a.kind,
               pg_catalog.jsonb_build_object('title', e.title, 'author', e.author, 'isbn', e.isbn, 'cover_url', e.cover_url,
                   'catalog_id', case when b.provider = 'google' then b.provider_id else b.provider || ':' || b.provider_id end)
          from recent a
          join public.textual_reviews r on r.user_id = a.actor_id and r.work_id = a.review_work_id
               and not r.deleted and not r.excluded and r.content->>'visibility' = 'public'
               and pg_catalog.jsonb_typeof(r.content->'rating') = 'number' and (r.content->>'rating')::integer >= 16
          join public.textual_library_entries e on e.user_id = a.actor_id and e.book_id = r.book_id and e.deleted_at is null
          join public.textual_books b on b.id = a.book_id
         where a.kind = 'review'
    ), contributions as (
        select * from shelf union all select * from events
    ), scored as (
        select c.book_id,
               pg_catalog.sum(c.weight) + 1.5 * (pg_catalog.count(distinct c.friend) - 1) as score,
               pg_catalog.array_agg(distinct c.source order by c.source) as sources,
               (pg_catalog.array_agg(c.display order by (coalesce(c.display->>'cover_url', '') <> '') desc,
                                     c.weight desc, c.friend))[1] as display
          from contributions c
         group by c.book_id
    ), page as (
        select * from scored s
         where (p_after_score is null or s.score < p_after_score or (s.score = p_after_score and s.book_id > p_after_book))
           -- Books already in the viewer's archive are left out, as For You does.
           and not exists (select 1 from public.textual_library_entries own
                            where own.user_id = v_user and own.book_id = s.book_id and own.deleted_at is null)
         order by s.score desc, s.book_id
         limit v_limit + 1
    )
    select coalesce(pg_catalog.jsonb_agg(pg.display || pg_catalog.jsonb_build_object(
                'book_id', pg.book_id, 'score', pg.score, 'sources', pg_catalog.to_jsonb(pg.sources))
                order by pg.score desc, pg.book_id), '[]'::jsonb), pg_catalog.count(*)
      into v_rows, v_count
      from page pg;

    return pg_catalog.jsonb_build_object(
        'snapshot', v_snapshot,
        'has_friends', v_friend_count > 0,
        'books', case when v_count > v_limit then v_rows - v_limit else v_rows end,
        'next', case when v_count > v_limit then pg_catalog.jsonb_build_object(
            'score', (v_rows->(v_limit - 1))->'score', 'book_id', (v_rows->(v_limit - 1))->'book_id') end);
end
$function$;

revoke all on function public.textual_read_feed(timestamptz, timestamptz, uuid, integer),
    public.textual_read_friend_discovery(timestamptz, numeric, uuid, integer)
    from public, anon, authenticated, service_role;
grant execute on function public.textual_read_feed(timestamptz, timestamptz, uuid, integer),
    public.textual_read_friend_discovery(timestamptz, numeric, uuid, integer)
    to authenticated;

commit;
