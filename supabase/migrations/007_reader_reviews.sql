-- Review foundation. Apply after 004; independent of public profile migrations.
-- No existing import is published or converted into a community contribution.
begin;

create table public.textual_review_works (
    id uuid primary key default pg_catalog.gen_random_uuid()
);
create table public.textual_review_book_links (
    book_id uuid primary key references public.textual_books(id),
    work_id uuid not null references public.textual_review_works(id)
);
create index textual_review_links_work on public.textual_review_book_links(work_id);
-- Conservatively retain provider identity until a trusted catalog resolver verifies
-- cross-provider/edition equivalence. Clients cannot create or change these links.
insert into public.textual_review_works(id) select id from public.textual_books;
insert into public.textual_review_book_links select id, id from public.textual_books;
create function public.textual_create_review_identity() returns trigger
language plpgsql security definer set search_path = '' as $$
begin
    insert into public.textual_review_works(id) values (new.id);
    insert into public.textual_review_book_links values (new.id, new.id);
    return new;
end $$;
create trigger textual_review_identity after insert on public.textual_books
for each row execute function public.textual_create_review_identity();

create table public.textual_review_terms (
    kind text not null check (kind in ('mood','genre')),
    slug text not null check (slug ~ '^[a-z][a-z0-9-]{0,63}$'),
    label text not null,
    primary key(kind, slug)
);
insert into public.textual_review_terms(kind,slug,label)
select 'mood', x, pg_catalog.initcap(x) from unnest(array[
    'dark','tense','adventurous','mysterious','reflective','emotional','inspiring',
    'informative','funny','sad','hopeful','lighthearted']) x;
insert into public.textual_review_terms(kind,slug,label)
select 'genre', x, pg_catalog.initcap(replace(x,'-',' ')) from unnest(array[
    'fantasy','romance','memoir','biography','young-adult','middle-grade','historical',
    'literary','thriller','mystery','crime','true-crime','self-help','lgbtqia','feminism',
    'science-fiction','poetry','dystopian','contemporary','horror','adventure','art',
    'essays','classics','health','politics','philosophy','psychology','history',
    'business','science','religion','travel','cooking','humor','graphic-novels',
    'short-stories','drama','music','sports','nature','technology','education','childrens','erotica','western']) x;
update public.textual_review_terms set label='LGBTQIA+' where kind='genre' and slug='lgbtqia';
update public.textual_review_terms set label='Children’s' where kind='genre' and slug='childrens';

create function public.textual_valid_review(p jsonb) returns boolean
language plpgsql stable set search_path = '' as $$
declare k text; a jsonb;
begin
    if p is null or jsonb_typeof(p) <> 'object' or octet_length(p::text) > 100000
       or not (p ?& array['version','body','spoilers','moods','genres','visibility','contribute'])
       or exists(select 1 from jsonb_object_keys(p) x where x not in
          ('version','body','spoilers','moods','genres','visibility','contribute','rating','pace','fiction'))
       or p->'version' is distinct from '1'::jsonb then return false; end if;
    if jsonb_typeof(p->'body') <> 'string' or char_length(p->>'body') > 20000
       or jsonb_typeof(p->'spoilers') <> 'boolean' or jsonb_typeof(p->'contribute') <> 'boolean'
       or p->>'visibility' not in ('private','public') or jsonb_typeof(p->'visibility') <> 'string'
       then return false; end if;
    if p ? 'rating' and p->'rating' <> 'null'::jsonb then
        if jsonb_typeof(p->'rating') <> 'number' or p->>'rating' !~ '^[0-9]{1,2}$'
           or (p->>'rating')::int > 20 then return false; end if;
    end if;
    if p ? 'pace' and p->'pace' <> 'null'::jsonb and
       (jsonb_typeof(p->'pace') <> 'string' or p->>'pace' not in ('fast','medium','slow')) then return false; end if;
    if p ? 'fiction' and p->'fiction' <> 'null'::jsonb and
       (jsonb_typeof(p->'fiction') <> 'string' or p->>'fiction' not in ('fiction','nonfiction')) then return false; end if;
    foreach k in array array['moods','genres'] loop
        a := p->k;
        if jsonb_typeof(a) <> 'array' then return false; end if;
        if jsonb_array_length(a) > 12 then return false; end if;
        if exists(select 1 from jsonb_array_elements(a) v where jsonb_typeof(v) <> 'string') then return false; end if;
        if (select count(distinct v) from jsonb_array_elements_text(a) v) <> jsonb_array_length(a) then return false; end if;
        if exists(select 1 from jsonb_array_elements_text(a) v where not exists(
            select 1 from public.textual_review_terms t where t.kind = case k when 'moods' then 'mood' else 'genre' end and t.slug = v)) then return false; end if;
    end loop;
    return true;
end $$;

create table public.textual_reviews (
    user_id uuid not null references auth.users(id) on delete cascade,
    work_id uuid not null references public.textual_review_works(id),
    book_id uuid not null references public.textual_books(id),
    content jsonb not null check (public.textual_valid_review(content)),
    revision bigint not null check(revision > 0),
    updated_at timestamptz not null default clock_timestamp(),
    deleted boolean not null default false,
    excluded boolean not null default false, -- moderation; never client writable
    primary key(user_id,work_id)
);
create index textual_reviews_work on public.textual_reviews(work_id) where not deleted and not excluded;
create table public.textual_review_operations (
    user_id uuid not null references auth.users(id) on delete cascade,
    operation_id uuid not null,
    request jsonb not null,
    response jsonb not null,
    primary key(user_id, operation_id)
);
create table public.textual_review_summaries (
    work_id uuid primary key references public.textual_review_works(id),
    summary jsonb not null,
    updated_at timestamptz not null default clock_timestamp()
);

-- Recompute only the affected book on a write, never scan reviews on a stats read.
-- Work-row locks serialize concurrent contributors. The trigger also handles
-- moderation, privacy withdrawal, deletion, and account deletion cascades.
create function public.textual_refresh_review_summary() returns trigger
language plpgsql security definer set search_path = '' as $$
declare w uuid := coalesce(new.work_id, old.work_id); s jsonb; k text; n int; counts jsonb;
begin
    perform 1 from public.textual_review_works where id = w for update;
    s := jsonb_build_object('minimumContributors',5);
    foreach k in array array['pace','fiction','rating','moods','genres'] loop
        select count(*) into n from public.textual_reviews r where r.work_id = w
          and not r.deleted and not r.excluded and r.content->'contribute' = 'true'::jsonb
          and case when k in ('moods','genres') then jsonb_array_length(r.content->k) > 0
              else coalesce(r.content->k,'null'::jsonb) <> 'null'::jsonb end;
        if n >= 5 then
            select coalesce(jsonb_object_agg(value, votes),'{}'::jsonb) into counts from (
                select v.value, count(*) votes from public.textual_reviews r
                cross join lateral jsonb_array_elements_text(case when k in ('moods','genres') then r.content->k
                    else jsonb_build_array(r.content->k) end) v
                where r.work_id = w and not r.deleted and not r.excluded
                    and r.content->'contribute' = 'true'::jsonb and v.value is not null
                group by v.value
            ) tally;
            s := s || jsonb_build_object(k,jsonb_build_object('contributors',n,'counts',counts));
        end if;
    end loop;
    insert into public.textual_review_summaries(work_id,summary) values(w,s)
    on conflict(work_id) do update set summary=excluded.summary,updated_at=clock_timestamp();
    return null;
end $$;
create trigger textual_review_summary after insert or update or delete on public.textual_reviews
for each row execute function public.textual_refresh_review_summary();

create function public.textual_review_json(r public.textual_reviews) returns jsonb
language sql stable set search_path = '' as $$
 select jsonb_build_object('workID',r.work_id,'bookID',r.book_id,'revision',r.revision,
    'content',r.content,'deleted',r.deleted)
$$;
create function public.textual_read_own_review(p_expected_user_id uuid,p_book_id uuid) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare r public.textual_reviews;
begin
    if auth.uid() is null or p_expected_user_id is distinct from auth.uid() then
       raise exception using errcode='42501',message='Account changed.'; end if;
    select x.* into r from public.textual_reviews x join public.textual_review_book_links b on b.work_id=x.work_id
      where b.book_id=p_book_id and x.user_id=auth.uid();
    if not found then return null; end if;
    return public.textual_review_json(r);
end $$;

create function public.textual_save_review(p_expected_user_id uuid,p_operation_id uuid,
    p_book_id uuid,p_expected_revision bigint,p_content jsonb,p_deleted boolean default false) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare u uuid := auth.uid(); w uuid; r public.textual_reviews; req jsonb; prior jsonb; answer jsonb;
begin
    if u is null or p_expected_user_id is distinct from u then
        raise exception using errcode='42501',message='Account changed.'; end if;
    if p_operation_id is null or p_book_id is null or p_expected_revision is null or p_expected_revision < 0
       or p_deleted is null or not public.textual_valid_review(p_content) then
        raise exception using errcode='22023',message='Invalid review.'; end if;
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
    if coalesce(r.revision,0) <> p_expected_revision then
        answer := jsonb_build_object('status','conflict','review',case when r.user_id is null then null else public.textual_review_json(r) end);
    else
        insert into public.textual_reviews(user_id,work_id,book_id,content,revision,deleted)
        values(u,w,p_book_id,p_content,p_expected_revision+1,p_deleted)
        on conflict(user_id,work_id) do update set book_id=excluded.book_id,content=excluded.content,
            revision=excluded.revision,deleted=excluded.deleted,updated_at=clock_timestamp()
        returning * into r;
        answer := jsonb_build_object('status','applied','review',public.textual_review_json(r));
    end if;
    insert into public.textual_review_operations values(u,p_operation_id,req,answer);
    return answer;
end $$;

create function public.textual_read_review_summary(p_book_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
    select coalesce(s.summary,jsonb_build_object('minimumContributors',5))
    from public.textual_review_book_links b left join public.textual_review_summaries s on s.work_id=b.work_id
    where b.book_id=p_book_id and auth.uid() is not null
$$;

-- Every exposed object starts closed. Only owner reads + narrow authenticated RPCs.
alter table public.textual_review_works enable row level security;
alter table public.textual_review_book_links enable row level security;
alter table public.textual_review_terms enable row level security;
alter table public.textual_reviews enable row level security;
alter table public.textual_review_operations enable row level security;
alter table public.textual_review_summaries enable row level security;
revoke all on public.textual_review_works,public.textual_review_book_links,public.textual_review_terms,
    public.textual_reviews,public.textual_review_operations,public.textual_review_summaries from public,anon,authenticated;
grant select on public.textual_review_terms,public.textual_reviews to authenticated;
create policy textual_review_terms_read on public.textual_review_terms for select to authenticated using (auth.uid() is not null);
create policy textual_reviews_owner on public.textual_reviews for select to authenticated using (user_id=auth.uid());
revoke all on function public.textual_create_review_identity(),public.textual_valid_review(jsonb),
    public.textual_refresh_review_summary(),public.textual_review_json(public.textual_reviews),
    public.textual_read_own_review(uuid,uuid),public.textual_save_review(uuid,uuid,uuid,bigint,jsonb,boolean),
    public.textual_read_review_summary(uuid) from public,anon,authenticated;
grant execute on function public.textual_read_own_review(uuid,uuid),
    public.textual_save_review(uuid,uuid,uuid,bigint,jsonb,boolean),public.textual_read_review_summary(uuid) to authenticated;
-- Trusted catalog administration only. A verified edition/work match must be
-- established outside the client; never invoke this from title similarity alone.
create function public.textual_merge_review_works(p_source uuid,p_target uuid) returns void
language plpgsql security definer set search_path = '' as $$
declare source_review public.textual_reviews; target_review public.textual_reviews;
begin
    if p_source is null or p_target is null or p_source=p_target then
        raise exception using errcode='22023',message='Two different work IDs are required.'; end if;
    perform 1 from public.textual_review_works where id in (p_source,p_target) order by id for update;
    if (select count(*) from public.textual_review_works where id in (p_source,p_target)) <> 2 then
        raise exception using errcode='22023',message='Unknown work.'; end if;
    for source_review in select * from public.textual_reviews where work_id=p_source loop
        select * into target_review from public.textual_reviews
            where work_id=p_target and user_id=source_review.user_id;
        if found then
            -- Keep the most recent assessment, including withdrawal, rather than
            -- adding a second vote. A moderation exclusion follows either copy.
            if source_review.updated_at > target_review.updated_at then
                update public.textual_reviews set content=source_review.content,book_id=source_review.book_id,
                    deleted=source_review.deleted,excluded=source_review.excluded or target_review.excluded,
                    revision=greatest(source_review.revision,target_review.revision)+1,updated_at=source_review.updated_at
                where user_id=source_review.user_id and work_id=p_target;
            else
                update public.textual_reviews set excluded=source_review.excluded or target_review.excluded,
                    revision=greatest(source_review.revision,target_review.revision)+1
                where user_id=source_review.user_id and work_id=p_target;
            end if;
            delete from public.textual_reviews where user_id=source_review.user_id and work_id=p_source;
        else
            update public.textual_reviews set work_id=p_target,revision=revision+1
                where user_id=source_review.user_id and work_id=p_source;
        end if;
    end loop;
    update public.textual_review_book_links set work_id=p_target where work_id=p_source;
    delete from public.textual_review_summaries where work_id=p_source;
    delete from public.textual_review_works where id=p_source;
end $$;
revoke all on function public.textual_merge_review_works(uuid,uuid) from public,anon,authenticated;
grant execute on function public.textual_merge_review_works(uuid,uuid) to service_role;

commit;
