// Disposable in-memory PostgreSQL only. Never connects to Supabase or real accounts.
// Run with PGLITE_MODULE pointing to an installed @electric-sql/pglite module.
import { readFile } from 'node:fs/promises';
import assert from 'node:assert/strict';
const { PGlite } = await import(process.env.PGLITE_MODULE ?? '@electric-sql/pglite');
const db = new PGlite();
const root = process.env.TEXTUAL_ROOT ?? new URL('../..', import.meta.url).pathname;
await db.exec(`create role anon; create role authenticated; create role service_role;
create schema auth; create table auth.users(id uuid primary key);
create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
grant usage on schema auth to anon,authenticated; grant execute on function auth.uid() to anon,authenticated;`);
for (const file of ['001_textual_accounts.sql','004_storygraph_import.sql','007_reader_reviews.sql']) {
    await db.exec(await readFile(`${root}/supabase/migrations/${file}`,'utf8'));
}
const uid = n => `00000000-0000-0000-0000-${String(n).padStart(12,'0')}`;
const book = uid(101), edition = uid(102), other = uid(103);
await db.query(`insert into public.textual_books(id,provider,provider_id) values ($1,'google','test-book'),($2,'google','test-edition'),($3,'google','other-book')`,[book,edition,other]);
// Trusted verified mapping: two editions of one work. Never client writable.
await db.query(`update public.textual_review_book_links set work_id=$1 where book_id=$2`,[book,edition]);
for(let n=1;n<=6;n++) {
    await db.query(`insert into auth.users values($1)`,[uid(n)]);
    await db.query(`insert into public.textual_library_entries(user_id,id,book_id,title,author,revision,updated_at) values($1,$2,$3,'Book','Writer',1,now())`,[uid(n),uid(200+n),book]);
}
await db.query(`insert into public.textual_library_entries(user_id,id,book_id,title,author,revision,updated_at) values($1,$2,$3,'Edition','Writer',2,now())`,[uid(1),uid(299),edition]);
let checks=0, op=1000;
const content = (extra={}) => ({version:1,body:'Private prose',spoilers:false,moods:['hopeful'],genres:['fantasy'],pace:'fast',visibility:'private',contribute:true,...extra});
async function asUser(n) { await db.exec('reset role'); await db.query(`select set_config('request.jwt.claim.sub',$1,false)`,[uid(n)]); await db.exec('set role authenticated'); }
async function save(n,{id=book,rev=0,payload=content(),deleted=false,operation=uid(++op)}={}) {
    const r=await db.query('select public.textual_save_review($1,$2,$3,$4,$5::jsonb,$6) result',[uid(n),operation,id,rev,JSON.stringify(payload),deleted]);return r.rows[0].result;
}
async function summary(id=book) { return (await db.query('select public.textual_read_review_summary($1) result',[id])).rows[0].result; }
async function denied(action) { await assert.rejects(action);checks++; }
await asUser(1);
const operation=uid(++op), first=await save(1,{operation});
assert.equal(first.review.revision,1);checks++;
assert.deepEqual(await save(1,{operation}),first);checks++;
await denied(()=>save(1,{operation,payload:content({body:'changed'})}));
await denied(()=>save(2));
await denied(()=>save(1,{id:other}));
await denied(()=>save(1,{payload:content({moods:['invented']})}));
await denied(()=>save(1,{payload:content({startedOn:'2026-01-01'})}));
await denied(()=>save(1,{payload:content({rating:21})}));
await denied(()=>save(1,{payload:content({moods:['hopeful','hopeful']})}));
await denied(()=>db.exec('update public.textual_reviews set excluded=false'));
await denied(()=>db.exec('select * from public.textual_review_summaries'));
await denied(()=>db.exec('update public.textual_review_book_links set work_id=book_id'));
assert.equal((await save(1,{rev:0})).status,'conflict');checks++;
assert.deepEqual(await summary(),{minimumContributors:5});checks++;
const changed=await save(1,{id:edition,rev:1,payload:content({pace:'medium'})});
assert.equal(changed.review.revision,2);checks++;
await asUser(2);
assert.equal((await db.query('select * from public.textual_reviews')).rows.length,0);checks++;
assert.equal((await db.query('select public.textual_read_own_review($1,$2) result',[uid(2),book])).rows[0].result,null);checks++;
for(let n=2;n<=5;n++){await asUser(n);await save(n,{payload:content({moods:n===5?[]:['hopeful']})});}
let s=await summary();
assert.deepEqual(s.pace,{contributors:5,counts:{fast:4,medium:1}});checks++;
assert.equal(s.moods,undefined);checks++;
assert.equal(JSON.stringify(s).includes('Private prose'),false);checks++;
assert.deepEqual(await summary(edition),s);checks++;
await asUser(6);await save(6,{payload:content({contribute:false})});
assert.deepEqual(await summary(),s);checks++;
await save(6,{rev:1,payload:content()});
s=await summary();assert.equal(s.pace.contributors,6);assert.equal(s.moods.contributors,5);checks++;
await save(6,{rev:2,payload:content({contribute:false})});
assert.equal((await summary()).pace.contributors,5);checks++;
await asUser(5);await save(5,{rev:1,deleted:true,payload:content({contribute:false,body:'',moods:[],genres:[]})});
assert.deepEqual(await summary(),{minimumContributors:5});checks++;
// Moderation and account deletion must remove existing contributions as well.
await save(5,{rev:2});
await db.exec('reset role');await db.query('update public.textual_reviews set excluded=true where user_id=$1',[uid(5)]);
await asUser(1);assert.deepEqual(await summary(),{minimumContributors:5});checks++;
await db.exec('reset role');await db.query('update public.textual_reviews set excluded=false where user_id=$1',[uid(5)]);
await db.query('delete from auth.users where id=$1',[uid(4)]);
await asUser(1);assert.deepEqual(await summary(),{minimumContributors:5});checks++;
await db.exec('reset role; set role anon');
await denied(()=>db.query('select public.textual_read_review_summary($1)',[book]));
await denied(()=>db.exec('select * from public.textual_reviews'));
await denied(()=>db.query('select public.textual_read_own_review($1,$2)',[uid(1),book]));
await db.exec('reset role');
await db.query(`insert into public.textual_library_entries(user_id,id,book_id,title,author,revision,updated_at) values($1,$2,$3,'Other edition','Writer',3,now())`,[uid(1),uid(398),other]);
await asUser(1);
await save(1,{id:other,payload:content({pace:'slow',body:'Latest edition assessment'})});
await denied(()=>db.query('select public.textual_merge_review_works($1,$2)',[other,book]));
await db.exec('reset role; set role service_role');
await db.query('select public.textual_merge_review_works($1,$2)',[other,book]);
await asUser(1);
const own = (await db.query('select public.textual_read_own_review($1,$2) result',[uid(1),book])).rows[0].result;
assert.equal(own.content.body,'Latest edition assessment');checks++;
assert.equal((await db.query('select * from public.textual_reviews')).rows.length,1);checks++;
assert.deepEqual(await summary(other),await summary(book));checks++;
await db.exec('reset role');
await db.query('update public.textual_library_entries set deleted_at=now() where user_id=$1',[uid(6)]);
await asUser(6);
await denied(()=>save(6,{rev:3}));
assert.equal((await save(6,{rev:3,deleted:true,payload:content({contribute:false})})).status,'applied');checks++;
await db.close();
console.log(`${checks} review database checks passed (isolated in-memory PostgreSQL).`);
