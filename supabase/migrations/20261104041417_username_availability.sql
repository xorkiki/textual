-- Signup preflight only. The existing normalized UNIQUE(username) constraint
-- and textual_upsert_profile still arbitrate simultaneous profile claims.
begin;

create function public.textual_username_available(p_username text)
returns boolean
language plpgsql
stable
security definer
set search_path = ''
as $function$
declare
    v_username text := pg_catalog.lower(pg_catalog.btrim(p_username));
begin
    if v_username is null or pg_catalog.octet_length(v_username) > 30
       or v_username !~ '^[a-z0-9_]{3,30}$' then
        return false;
    end if;
    -- Normalize the parameter, not the indexed column: a single index lookup.
    return not exists (
        select 1 from public.textual_profiles where username = v_username
    );
end
$function$;

-- Deliberately callable before authentication. SECURITY DEFINER is needed to
-- check all claimed names behind owner-only RLS; expose only a boolean for one
-- exact valid name, never profile rows, account IDs, emails, or search results.
revoke all on function public.textual_username_available(text)
    from public, anon, authenticated, service_role;
grant execute on function public.textual_username_available(text) to anon, authenticated;
comment on function public.textual_username_available(text) is
    'Exact-name signup availability only, not a reservation. Atomic uniqueness remains enforced by textual_profiles_username_key.';

commit;
