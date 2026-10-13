-- Discover refresh schedule. Run once in the Supabase SQL Editor after
-- 009_discovery.sql is applied and the `discovery-refresh` Edge Function is deployed.
-- Safe to rerun: it reuses the existing token and replaces the three jobs.
--
-- Before running, replace the project URL on the marked line. It is not a secret.
-- The caller token is generated here inside the database and stored in Vault; no
-- one types, copies, or bundles it. Requires the pg_cron, pg_net, and Vault
-- integrations (available on every Supabase plan).

create extension if not exists pg_net;
create extension if not exists pg_cron;

do $setup$
begin
    if not exists (select 1 from vault.secrets where name = 'textual_discovery_cron_token') then
        perform vault.create_secret(
            encode(extensions.gen_random_bytes(32), 'hex'),
            'textual_discovery_cron_token',
            'Caller token for the Textual discovery-refresh Edge Function');
    end if;
end
$setup$;

create or replace function public.textual_trigger_discovery_refresh(p_jobs text[])
returns bigint
language sql
security definer
set search_path = ''
as $function$
    select net.http_post(
        -- Replace with your project URL, for example https://abcdefgh.supabase.co
        url := 'https://YOUR_PROJECT.supabase.co' || '/functions/v1/discovery-refresh',
        headers := pg_catalog.jsonb_build_object(
            'Content-Type', 'application/json',
            'x-textual-discovery-token', (select decrypted_secret from vault.decrypted_secrets
                                          where name = 'textual_discovery_cron_token')),
        body := pg_catalog.jsonb_build_object('jobs', p_jobs),
        timeout_milliseconds := 10000)
$function$;
revoke all on function public.textual_trigger_discovery_refresh(text[]) from public, anon, authenticated, service_role;

-- Trending every six hours keeps any NYT-derived rows inside their 24-hour cache
-- limit; Apple's charts update daily. New releases daily. Explore refreshes the six
-- stalest of its 26 subject/era/origin pools every four hours (all of them daily).
select cron.schedule('textual-discovery-trending', '15 */6 * * *',
    $$select public.textual_trigger_discovery_refresh(array['trending'])$$);
select cron.schedule('textual-discovery-new-releases', '40 5 * * *',
    $$select public.textual_trigger_discovery_refresh(array['new_releases'])$$);
select cron.schedule('textual-discovery-explore', '25 */4 * * *',
    $$select public.textual_trigger_discovery_refresh(array['explore'])$$);

-- First fill (optional): run each line a few minutes apart, then check the Edge
-- Function logs. Explore needs about five runs to fill every pool initially.
-- select public.textual_trigger_discovery_refresh(array['new_releases']);
-- select public.textual_trigger_discovery_refresh(array['explore']);
-- select public.textual_trigger_discovery_refresh(array['trending']);
