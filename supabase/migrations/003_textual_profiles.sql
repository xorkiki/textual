-- Private onboarding profiles. Apply after 001 as the migration owner.
-- No signup triggers, email duplication, or anonymous username directory.
begin;

do $preflight$
begin
    if pg_catalog.to_regclass('public.textual_profiles') is not null
       or exists (
           select 1 from pg_catalog.pg_proc p
           join pg_catalog.pg_namespace n on n.oid = p.pronamespace
           where n.nspname = 'public' and p.proname = 'textual_upsert_profile'
       ) then
        raise exception 'Textual profile objects already exist; review migration history first.';
    end if;
    if pg_catalog.to_regclass('auth.users') is null
       or pg_catalog.to_regprocedure('auth.uid()') is null then
        raise exception 'Supabase Auth must exist before Textual profiles are installed.';
    end if;
end
$preflight$;

create table public.textual_profiles (
    user_id uuid primary key references auth.users(id) on delete cascade,
    first_name text not null check (
        first_name = pg_catalog.btrim(first_name)
        and pg_catalog.char_length(first_name) between 1 and 80
        and first_name !~ '[[:cntrl:]]'
    ),
    username text not null unique check (
        username = pg_catalog.lower(pg_catalog.btrim(username))
        and username ~ '^[a-z0-9_]{3,30}$'
    ),
    created_at timestamptz not null default pg_catalog.clock_timestamp(),
    updated_at timestamptz not null default pg_catalog.clock_timestamp()
);

alter table public.textual_profiles enable row level security;
revoke all on public.textual_profiles from public, anon, authenticated, service_role;
grant select on public.textual_profiles to authenticated;
create policy textual_profile_owner_read on public.textual_profiles
    for select to authenticated using (user_id = (select auth.uid()));

create function public.textual_upsert_profile(
    p_expected_user_id uuid,
    p_first_name text,
    p_username text
)
returns jsonb
language plpgsql
security definer
set search_path = ''
as $function$
declare
    v_user_id uuid := auth.uid();
    v_first_name text := pg_catalog.btrim(p_first_name);
    v_username text := pg_catalog.lower(pg_catalog.btrim(p_username));
    v_profile public.textual_profiles%rowtype;
begin
    if v_user_id is null then
        raise exception using errcode = '42501', message = 'Authentication is required.';
    end if;
    if p_expected_user_id is null or p_expected_user_id <> v_user_id then
        raise exception using errcode = '42501', message = 'Account changed before profile save. Retry for the original account.';
    end if;
    if v_first_name is null or pg_catalog.char_length(v_first_name) not between 1 and 80
       or v_first_name ~ '[[:cntrl:]]' then
        raise exception using errcode = '22023', message = 'First name must contain 1 to 80 characters without control characters.';
    end if;
    if v_username is null or v_username !~ '^[a-z0-9_]{3,30}$' then
        raise exception using errcode = '22023', message = 'Username must contain 3 to 30 letters, numbers, or underscores.';
    end if;

    insert into public.textual_profiles(user_id, first_name, username)
    values (v_user_id, v_first_name, v_username)
    on conflict (user_id) do update set
        first_name = excluded.first_name,
        username = excluded.username,
        updated_at = pg_catalog.clock_timestamp()
    returning * into v_profile;

    return pg_catalog.jsonb_build_object(
        'user_id', v_profile.user_id, 'first_name', v_profile.first_name,
        'username', v_profile.username, 'created_at', v_profile.created_at,
        'updated_at', v_profile.updated_at
    );
exception
    when unique_violation then
        -- Do not expose a competing account's ID or profile in error details.
        raise exception using errcode = '23505', message = 'Username is unavailable.';
end
$function$;

revoke all on function public.textual_upsert_profile(uuid, text, text)
    from public, anon, authenticated, service_role;
grant execute on function public.textual_upsert_profile(uuid, text, text) to authenticated;

comment on table public.textual_profiles is 'Owner-private onboarding profile. Usernames are normalized and globally unique; no email or public discovery endpoint.';
comment on function public.textual_upsert_profile(uuid, text, text) is 'Call after an authenticated confirmed session exists. auth.uid owns the row; expected user ID prevents account-switch races. SQLSTATE23505 means username unavailable.';

commit;
