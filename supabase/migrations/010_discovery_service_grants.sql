-- Apply after 009. Projects created with restricted default privileges don't grant the
-- service role access to new tables, so the refresh function's direct reads failed.
-- Grants cover only the new Discover tables; existing tables are unchanged.
begin;
grant select on public.textual_discovery_books, public.textual_discovery_collections to service_role;
grant select, insert, update on public.textual_discovery_resolutions to service_role;
commit;
