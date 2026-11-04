-- Public profile friendships. Only accepted edges are visible; pending requests
-- remain private to their participants. The relationship is always from the
-- authenticated viewer's perspective and is evaluated afresh for each page.
create function public.textual_read_profile_friends(
    p_username text, p_after_username text default null, p_limit integer default 40)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $function$
declare
    v_viewer uuid := auth.uid();
    v_owner uuid;
    v_limit integer := least(greatest(coalesce(p_limit, 40), 1), 100);
    v_rows jsonb;
    v_count integer;
begin
    if v_viewer is null then
        raise exception using errcode = '42501', message = 'Authentication is required.';
    end if;
    select p.user_id into v_owner from public.textual_profiles p
     where p.username = pg_catalog.lower(pg_catalog.btrim(coalesce(p_username, '')));
    if v_owner is null then
        raise exception using errcode = 'P0002', message = 'That reader couldn’t be found.';
    end if;

    with page as (
        select p.user_id, p.username
          from public.textual_friendships f
          join public.textual_profiles p on p.user_id =
               case when f.user_low = v_owner then f.user_high else f.user_low end
         where (f.user_low = v_owner or f.user_high = v_owner)
           and f.status = 'accepted'
           and (p_after_username is null or p.username > p_after_username)
         order by p.username
         limit v_limit + 1
    )
    select coalesce(pg_catalog.jsonb_agg(
               public.textual_reader_identity(pg.user_id) || pg_catalog.jsonb_build_object(
                   'relationship', case when pg.user_id = v_viewer then null
                       else public.textual_relationship(v_viewer, pg.user_id) end)
               order by pg.username), '[]'::jsonb), pg_catalog.count(*)
      into v_rows, v_count from page pg;

    return pg_catalog.jsonb_build_object(
        'friends', case when v_count > v_limit then v_rows - v_limit else v_rows end,
        'next', case when v_count > v_limit then (v_rows->(v_limit - 1))->>'username' end);
end
$function$;

revoke all on function public.textual_read_profile_friends(text, text, integer)
    from public, anon, authenticated, service_role;
grant execute on function public.textual_read_profile_friends(text, text, integer)
    to authenticated;
