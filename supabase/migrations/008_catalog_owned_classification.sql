-- Catalog classifications are public metadata, not reviewer responsibilities.
-- Additive upgrade after 007. Legacy payloads still decode, but classification
-- answers are not exposed, requested, or counted in community summaries.
begin;
create or replace function public.textual_valid_review(p jsonb) returns boolean
language plpgsql stable set search_path = '' as $$
declare k text; a jsonb;
begin
    if p is null or jsonb_typeof(p) <> 'object' or octet_length(p::text) > 100000
       or not (p ?& array['version','body','spoilers','moods','visibility','contribute'])
       or exists(select 1 from jsonb_object_keys(p) x where x not in
          ('version','body','spoilers','moods','visibility','contribute','rating','pace','fiction','genres'))
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
    foreach k in array array['moods'] loop
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

create or replace function public.textual_refresh_review_summary() returns trigger
language plpgsql security definer set search_path = '' as $$
declare w uuid := coalesce(new.work_id, old.work_id); s jsonb; k text; n int; counts jsonb;
begin
    perform 1 from public.textual_review_works where id = w for update;
    s := jsonb_build_object('minimumContributors',5);
    foreach k in array array['pace','rating','moods'] loop
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

create or replace function public.textual_review_json(r public.textual_reviews) returns jsonb
language sql stable set search_path = '' as $$
 select jsonb_build_object('workID',r.work_id,'bookID',r.book_id,'revision',r.revision,
    'content',r.content - 'genres' - 'fiction','deleted',r.deleted)
$$;
create or replace function public.textual_read_review_summary(p_book_id uuid) returns jsonb
language sql stable security definer set search_path = '' as $$
    select coalesce(s.summary - 'genres' - 'fiction',jsonb_build_object('minimumContributors',5))
    from public.textual_review_book_links b left join public.textual_review_summaries s on s.work_id=b.work_id
    where b.book_id=p_book_id and auth.uid() is not null
$$;
drop policy textual_review_terms_read on public.textual_review_terms;
create policy textual_review_terms_read on public.textual_review_terms for select to authenticated
    using (auth.uid() is not null and kind='mood');
-- Stored legacy summaries are left intact; the read boundary removes obsolete
-- fields immediately and the next contribution refreshes the cached summary.
commit;
