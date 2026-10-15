-- Let an authenticated user permanently delete their own account and all
-- account-owned rows that reference auth.users(id) with ON DELETE CASCADE.
create or replace function public.textual_delete_account(p_expected_user_id uuid)
returns void
language plpgsql
security definer
set search_path = pg_catalog, public
as $$
declare
    v_user_id uuid := auth.uid();
begin
    if v_user_id is null or p_expected_user_id is null or p_expected_user_id <> v_user_id then
        raise exception using errcode = '42501', message = 'The active account must own the deletion request.';
    end if;

    delete from auth.users where id = v_user_id;
end;
$$;

revoke all on function public.textual_delete_account(uuid) from public, anon, authenticated, service_role;
grant execute on function public.textual_delete_account(uuid) to authenticated;

comment on function public.textual_delete_account(uuid) is
    'Permanently deletes the authenticated account. Account-owned Textual rows use ON DELETE CASCADE.';
