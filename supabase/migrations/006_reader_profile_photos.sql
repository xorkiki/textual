-- Apply after 005_public_reader_profiles.sql. Photos are visible to signed-in profile visitors.
-- A private bucket keeps pending/replaced photos visible only to their owner.
begin;

insert into storage.buckets(id, name, public, file_size_limit, allowed_mime_types)
values ('textual-avatars', 'textual-avatars', false, 2097152, array['image/jpeg'])
on conflict (id) do update set public = false, file_size_limit = 2097152,
    allowed_mime_types = array['image/jpeg'];

create function public.textual_can_read_avatar(p_name text)
returns boolean language sql stable security definer set search_path = ''
as $function$
    select auth.uid() is not null and (
        pg_catalog.split_part(p_name, '/', 1) = auth.uid()::text
        or exists (select 1 from public.textual_reader_profiles where content->>'avatarPath' = p_name)
    );
$function$;
revoke all on function public.textual_can_read_avatar(text) from public, anon, authenticated, service_role;
grant execute on function public.textual_can_read_avatar(text) to authenticated;

create policy textual_avatar_read on storage.objects for select to authenticated
using (bucket_id = 'textual-avatars' and public.textual_can_read_avatar(name));

create policy textual_avatar_insert on storage.objects for insert to authenticated
with check (bucket_id = 'textual-avatars' and auth.uid() is not null
    and name ~ ('^' || auth.uid()::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'));

-- Uploads use a new UUID for each selection; upsert supports a retry after a lost response.
create policy textual_avatar_update on storage.objects for update to authenticated
using (bucket_id = 'textual-avatars' and pg_catalog.split_part(name, '/', 1) = auth.uid()::text)
with check (bucket_id = 'textual-avatars' and auth.uid() is not null
    and name ~ ('^' || auth.uid()::text || '/[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}\.jpg$'));

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
       or exists (select 1 from pg_catalog.jsonb_object_keys(p_content) k where k not in ('stats', 'sentence', 'favorites', 'avatarPath')) then
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

commit;
