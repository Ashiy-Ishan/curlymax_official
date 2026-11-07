-- CURLYmax: run once in the Supabase Dashboard SQL editor on a fresh project.
-- Schema only: no credentials or sample videos/quizzes.
begin;

-- 202611040001_catalog.sql
create extension if not exists pgcrypto;
create schema if not exists private;
revoke all on schema private from public, anon, authenticated;
create table private.owners (user_id uuid primary key references auth.users(id));
create function public.is_owner() returns boolean language sql stable security definer set search_path='' as $$ select exists(select 1 from private.owners where user_id=auth.uid()) $$;
revoke all on function public.is_owner() from public;
grant execute on function public.is_owner() to anon, authenticated;

create table public.channels (
 id uuid primary key default gen_random_uuid(), name text not null, handle text not null unique,
 active boolean not null default true, position int not null default 0
);
create table public.sections (
 id uuid primary key default gen_random_uuid(), channel_id uuid not null references public.channels,
 name text not null, position int not null default 0, active boolean not null default true,
 unique(id,channel_id)
);
create function public.youtube_id(url text) returns text language plpgsql immutable set search_path='' as $$
declare v text;
begin
 if url ~ '^https?://(www\.|m\.)?youtube\.com/watch\?' then v:=substring(url from '[?&]v=([A-Za-z0-9_-]{11})(&|#|$)');
 elsif url ~ '^https?://youtu\.be/' then v:=substring(url from '^https?://youtu\.be/([A-Za-z0-9_-]{11})([?/#]|$)');
 elsif url ~ '^https?://(www\.|m\.)?youtube\.com/shorts/' then v:=substring(url from '/shorts/([A-Za-z0-9_-]{11})([?/#]|$)'); end if;
 if v is null then raise exception 'Use a valid YouTube watch, youtu.be or Shorts URL'; end if;
 return v;
end $$;
create table public.videos (
 id uuid primary key default gen_random_uuid(), channel_id uuid not null references public.channels,
 section_id uuid not null, title text not null check(length(trim(title))>0), description text not null default '',
 youtube_url text not null, youtube_id text generated always as (public.youtube_id(youtube_url)) stored,
 status text not null default 'draft' check(status in ('draft','published')),
 published_at timestamptz, created_at timestamptz not null default now(),
 foreign key(section_id,channel_id) references public.sections(id,channel_id)
);
create table public.quizzes (
 id uuid primary key default gen_random_uuid(), video_id uuid not null references public.videos,
 title text not null, status text not null default 'draft' check(status in ('draft','published')),
 published_at timestamptz, created_at timestamptz not null default now()
);
create table public.questions (
 id uuid primary key default gen_random_uuid(), quiz_id uuid not null references public.quizzes on delete cascade,
 prompt text not null, options jsonb not null check(jsonb_typeof(options)='array' and jsonb_array_length(options) between 2 and 6),
 position int not null, unique(quiz_id,position)
);
create table private.answer_keys (
 question_id uuid primary key references public.questions on delete cascade,
 correct_index int not null check(correct_index between 0 and 5)
);
-- Exposed only to the owner so keys can be entered in Dashboard's SQL editor.
create function public.set_answer_key(question uuid, answer_index int) returns void
language plpgsql security definer set search_path='' as $$
begin
 if not public.is_owner() then raise exception 'Owner only' using errcode='42501'; end if;
 if not exists(select 1 from public.questions q join public.quizzes z on z.id=q.quiz_id where q.id=question and z.status='draft' and answer_index>=0 and answer_index<jsonb_array_length(q.options)) then raise exception 'Invalid question, index, or quiz is published'; end if;
 insert into private.answer_keys values(question,answer_index) on conflict(question_id) do update set correct_index=excluded.correct_index;
end $$;
create table public.notes (
 id uuid primary key default gen_random_uuid(), user_id uuid not null default auth.uid() references auth.users on delete cascade,
 video_id uuid not null references public.videos, body text not null check(length(body) between 1 and 20000),
 updated_at timestamptz not null default now()
);
create table public.attempts (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users on delete cascade,
 quiz_id uuid not null references public.quizzes, score int not null, total int not null,
 submitted_at timestamptz not null default now()
);
create table private.notification_outbox (
 id uuid primary key default gen_random_uuid(), kind text not null, item_id uuid not null,
 title text not null, state text not null default 'pending' check(state in ('pending','dispatching','sent','failed')),
 created_at timestamptz not null default now(), dispatched_at timestamptz, detail text,
 unique(kind,item_id)
);
create function public.video_visible(v uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.videos v1 join public.channels c on c.id=v1.channel_id join public.sections s on s.id=v1.section_id where v1.id=v and v1.status='published' and c.active and s.active)
$$;
create function public.quiz_visible(q uuid) returns boolean language sql stable security definer set search_path='' as $$
 select exists(select 1 from public.quizzes z where z.id=q and z.status='published' and public.video_visible(z.video_id))
$$;
create function private.publish_item() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if new.status='published' and (tg_op='INSERT' or old.status<>'published') then
  if tg_table_name='quizzes' then
   if not public.video_visible(new.video_id) then raise exception 'Publish the video first'; end if;
   if not exists(select 1 from public.questions where quiz_id=new.id) or exists(select 1 from public.questions q left join private.answer_keys k on k.question_id=q.id where q.quiz_id=new.id and (k.question_id is null or k.correct_index>=jsonb_array_length(q.options))) then raise exception 'Every quiz needs questions and valid answer keys'; end if;
  end if;
  new.published_at:=coalesce(new.published_at,now());
  insert into private.notification_outbox(kind,item_id,title) values(case when tg_table_name='videos' then 'video' else 'quiz' end,new.id,new.title) on conflict do nothing;
 end if;
 return new;
end $$;
create trigger video_publish before insert or update on public.videos for each row execute function private.publish_item();
create trigger quiz_publish before insert or update on public.quizzes for each row execute function private.publish_item();
-- Freeze published questions and keys. Unpublish before editing; previous attempts retain their score/total.
create function private.guard_question() returns trigger language plpgsql set search_path='' as $$
begin
 if exists(select 1 from public.quizzes where id=case when tg_op='DELETE' then old.quiz_id else new.quiz_id end and status='published') or (tg_op='UPDATE' and exists(select 1 from public.quizzes where id=old.quiz_id and status='published')) then raise exception 'Unpublish quiz before editing questions'; end if;
 if tg_op='DELETE' then return old; end if; return new;
end $$;
create trigger question_guard before insert or update or delete on public.questions for each row execute function private.guard_question();
create function public.submit_quiz(quiz uuid, answers jsonb) returns public.attempts
language plpgsql security definer set search_path='' as $$
declare n int; points int; result public.attempts;
begin
 if auth.uid() is null then raise exception 'Sign in required' using errcode='42501'; end if;
 perform 1 from public.quizzes where id=quiz for share;
 if not public.quiz_visible(quiz) then raise exception 'Quiz unavailable' using errcode='42501'; end if;
 select count(*) into n from public.questions where quiz_id=quiz;
 if answers is null or jsonb_typeof(answers)<>'object' or (select count(*) from jsonb_object_keys(answers))<>n or exists(select 1 from public.questions q where q.quiz_id=quiz and (not answers ? q.id::text or jsonb_typeof(answers->q.id::text)<>'number' or (answers->>q.id::text)!~'^[0-5]$' or (answers->>q.id::text)::int>=jsonb_array_length(q.options))) then raise exception 'Answer every question with a valid option'; end if;
 select count(*) into points from public.questions q join private.answer_keys k on k.question_id=q.id where q.quiz_id=quiz and k.correct_index=(answers->>q.id::text)::int;
 insert into public.attempts(user_id,quiz_id,score,total) values(auth.uid(),quiz,points,n) returning * into result;
 return result;
end $$;
revoke all on function public.submit_quiz(uuid,jsonb) from public, anon;
grant execute on function public.submit_quiz(uuid,jsonb) to authenticated;
revoke all on function public.set_answer_key(uuid,int) from public, anon;
grant execute on function public.set_answer_key(uuid,int) to authenticated;

alter table public.channels enable row level security;
alter table public.sections enable row level security;
alter table public.videos enable row level security;
alter table public.quizzes enable row level security;
alter table public.questions enable row level security;
alter table public.notes enable row level security;
alter table public.attempts enable row level security;
create policy channel_read on public.channels for select to anon,authenticated using(active or public.is_owner());
create policy section_read on public.sections for select to anon,authenticated using(public.is_owner() or (active and exists(select 1 from public.channels c where c.id=channel_id and c.active)));
create policy video_read on public.videos for select to anon,authenticated using(public.video_visible(id) or public.is_owner());
create policy quiz_read on public.quizzes for select to anon,authenticated using(public.quiz_visible(id) or public.is_owner());
create policy question_read on public.questions for select to authenticated using(public.quiz_visible(quiz_id) or public.is_owner());
create policy notes_own on public.notes for all to authenticated using(user_id=auth.uid()) with check(user_id=auth.uid() and public.video_visible(video_id));
create policy attempts_own on public.attempts for select to authenticated using(user_id=auth.uid());
create policy channel_owner on public.channels for all to authenticated using(public.is_owner()) with check(public.is_owner());
create policy section_owner on public.sections for all to authenticated using(public.is_owner()) with check(public.is_owner());
create policy video_owner on public.videos for all to authenticated using(public.is_owner()) with check(public.is_owner());
create policy quiz_owner on public.quizzes for all to authenticated using(public.is_owner()) with check(public.is_owner());
create policy question_owner on public.questions for all to authenticated using(public.is_owner()) with check(public.is_owner());
revoke all on public.channels,public.sections,public.videos,public.quizzes,public.questions,public.notes,public.attempts from anon,authenticated;
grant select on public.channels,public.sections,public.videos,public.quizzes to anon,authenticated;
grant select on public.questions,public.attempts to authenticated;
grant select,insert,update,delete on public.notes to authenticated;
grant insert,update,delete on public.channels,public.sections,public.videos,public.quizzes,public.questions to authenticated;
grant usage on schema private to service_role;
grant all on all tables in schema private to service_role;
-- Worker claims each publication once; ambiguous HTTP outcomes require operator review, never blind retries.
create function public.claim_notifications() returns setof private.notification_outbox language sql security definer set search_path='' as $$
 update private.notification_outbox set state='dispatching',dispatched_at=now() where id in (select id from private.notification_outbox where state='pending' order by created_at for update skip locked limit 50) returning *
$$;
create function public.finish_notification(event uuid, succeeded boolean, message text) returns void language sql security definer set search_path='' as $$
 update private.notification_outbox set state=case when succeeded then 'sent' else 'failed' end,detail=left(message,1000) where id=event and state='dispatching'
$$;
revoke all on function public.claim_notifications(),public.finish_notification(uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.claim_notifications(),public.finish_notification(uuid,boolean,text) to service_role;
insert into public.channels(id,name,handle) values('10000000-0000-0000-0000-000000000001','Ashiy Ish','@ashiy_ish');
insert into public.sections(id,channel_id,name) values('20000000-0000-0000-0000-000000000001','10000000-0000-0000-0000-000000000001','Latest videos');
alter publication supabase_realtime add table public.channels,public.sections,public.videos,public.quizzes;

-- 202611040002_publication_guards.sql
-- Do not alert for content hidden between publication and worker dispatch.
create or replace function public.claim_notifications() returns setof private.notification_outbox language sql security definer set search_path='' as $$
 update private.notification_outbox set state='dispatching',dispatched_at=now() where id in (
  select id from private.notification_outbox where state='pending' and
   ((kind='video' and public.video_visible(item_id)) or (kind='quiz' and public.quiz_visible(item_id)))
  order by created_at for update skip locked limit 50
 ) returning *
$$;
-- SQL CHECKs also prevent blank prompts and non-string choices being published.
alter table public.questions add constraint nonempty_prompt check(length(trim(prompt))>0);
create function private.valid_choices(choices jsonb) returns boolean language sql immutable set search_path='' as $$
 select not exists(select 1 from jsonb_array_elements(choices) as choice where jsonb_typeof(choice)<>'string' or length(trim(choice #>> '{}'))=0)
$$;
alter table public.questions add constraint valid_choice_text check(private.valid_choices(options));


-- 202611060003_quiz_feedback.sql
-- Add to the existing project once; no answer key becomes readable by viewers.
alter table private.answer_keys add column if not exists explanation text not null default '';
alter table public.attempts add column if not exists points int not null default 0;
create table private.quiz_runs (
 id uuid primary key default gen_random_uuid(), user_id uuid not null references auth.users on delete cascade,
 quiz_id uuid not null references public.quizzes on delete cascade, question_ids uuid[] not null,
 feedback jsonb not null default '{}'::jsonb, score int not null default 0,
 points int not null default 0, streak int not null default 0,
 attempt_id uuid references public.attempts on delete cascade, created_at timestamptz not null default now()
);
revoke all on private.quiz_runs from public,anon,authenticated;
-- Any dashboard or SQL edit invalidates unfinished runs with stale question content.
create function private.invalidate_quiz_runs() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 if tg_op <> 'INSERT' then delete from private.quiz_runs where quiz_id=old.quiz_id and attempt_id is null; end if;
 if tg_op <> 'DELETE' then delete from private.quiz_runs where quiz_id=new.quiz_id and attempt_id is null; end if;
 if tg_op='DELETE' then return old; end if; return new;
end $$;
create trigger question_run_invalidate before insert or update or delete on public.questions
for each row execute function private.invalidate_quiz_runs();
create function public.start_quiz_run(quiz uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare run private.quiz_runs; ids uuid[]; questions jsonb;
begin
 if auth.uid() is null then raise exception 'Sign in required' using errcode='42501'; end if;
 perform 1 from public.quizzes where id=quiz for share;
 if not public.quiz_visible(quiz) then raise exception 'Quiz unavailable' using errcode='42501'; end if;
 select array_agg(q.id order by q.position),jsonb_agg(jsonb_build_object('id',q.id,'prompt',q.prompt,'options',q.options) order by q.position)
 into ids,questions from public.questions q where q.quiz_id=quiz;
 if coalesce(array_length(ids,1),0)=0 then raise exception 'Quiz has no questions'; end if;
 insert into private.quiz_runs(user_id,quiz_id,question_ids) values(auth.uid(),quiz,ids) returning * into run;
 return jsonb_build_object('run_id',run.id,'questions',questions);
end $$;
create function public.answer_quiz_question(run_id uuid, question uuid, choice int) returns jsonb
language plpgsql security definer set search_path='' as $$
declare run private.quiz_runs; q public.questions; key private.answer_keys; correct boolean;
 response jsonb; count_answered int; bonus int:=0; attempt public.attempts;
begin
 if auth.uid() is null then raise exception 'Sign in required' using errcode='42501'; end if;
 select * into run from private.quiz_runs where id=run_id and user_id=auth.uid() for update;
 if not found then raise exception 'Run unavailable' using errcode='42501'; end if;
 -- Replayed requests return the original receipt without modifying points/streak/attempts.
 if run.feedback ? question::text then return run.feedback->question::text; end if;
 perform 1 from public.quizzes where id=run.quiz_id for share;
 if not public.quiz_visible(run.quiz_id) then raise exception 'Quiz unavailable' using errcode='42501'; end if;
 select count(*) into count_answered from jsonb_object_keys(run.feedback);
 if question is distinct from run.question_ids[count_answered+1] or run.attempt_id is not null then raise exception 'Answer the next question in order'; end if;
 select * into q from public.questions where id=question and quiz_id=run.quiz_id;
 if not found then raise exception 'Quiz changed; start again'; end if;
 if choice is null or choice<0 or choice>=jsonb_array_length(q.options) then raise exception 'Invalid option'; end if;
 select * into key from private.answer_keys where question_id=question;
 if not found then raise exception 'Answer unavailable'; end if;
 correct:=choice=key.correct_index;
 run.streak:=case when correct then run.streak+1 else 0 end;
 -- Once per non-overlapping three-correct milestone: 3, 6, 9, ...
 if correct and run.streak%3=0 then bonus:=50; end if;
 run.points:=run.points+case when correct then 100 else 0 end+bonus;
 run.score:=run.score+case when correct then 1 else 0 end;
 count_answered:=count_answered+1;
 if count_answered=array_length(run.question_ids,1) then
  insert into public.attempts(user_id,quiz_id,score,total,points)
  values(auth.uid(),run.quiz_id,run.score,count_answered,run.points) returning * into attempt;
  run.attempt_id:=attempt.id;
 end if;
 response:=jsonb_build_object('question_id',question,'choice',choice,'correct',correct,
 'correct_index',key.correct_index,'explanation',case when length(trim(key.explanation))>0 then key.explanation else 'The correct answer is '||(q.options->>key.correct_index)||'.' end,
 'awarded',case when correct then 100 else 0 end,'bonus',bonus,'points',run.points,'streak',run.streak,
 'score',run.score,'total',array_length(run.question_ids,1),'complete',run.attempt_id is not null,'attempt_id',run.attempt_id);
 update private.quiz_runs set feedback=run.feedback||jsonb_build_object(question::text,response),score=run.score,
 points=run.points,streak=run.streak,attempt_id=run.attempt_id where id=run.id;
 return response;
end $$;
revoke all on function public.start_quiz_run(uuid),public.answer_quiz_question(uuid,uuid,int) from public,anon;
grant execute on function public.start_quiz_run(uuid),public.answer_quiz_question(uuid,uuid,int) to authenticated;
-- Extend the owner's existing editor with explanations stored beside private keys.
create or replace function public.owner_quiz_questions(target uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not public.is_owner() then raise exception 'Owner only' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',q.id,'prompt',q.prompt,'options',q.options,'correct_index',k.correct_index,'explanation',k.explanation) order by q.position)
 from public.questions q left join private.answer_keys k on k.question_id=q.id where q.quiz_id=target),'[]'::jsonb);
end $$;
create or replace function public.owner_save_questions(target uuid, items jsonb) returns void
language plpgsql security definer set search_path='' as $$
declare item jsonb; question_id uuid; idx int:=0; choices jsonb; answer int;
begin
 if not public.is_owner() then raise exception 'Owner only' using errcode='42501'; end if;
 perform 1 from public.quizzes where id=target and status='draft' for update;
 if not found then raise exception 'Quiz missing or published. Unpublish before editing.'; end if;
 if jsonb_typeof(items) is distinct from 'array' or jsonb_array_length(items)>100 then raise exception 'Use an array of at most 100 questions'; end if;
 delete from public.questions where quiz_id=target;
 for item in select value from jsonb_array_elements(items) loop
  choices:=item->'options';
  if jsonb_typeof(choices) is distinct from 'array' then raise exception 'Options must be an array'; end if;
  if coalesce(item->>'correct_index','') !~ '^[0-5]$' then raise exception 'Choose a valid answer'; end if;
  answer:=(item->>'correct_index')::int;
  if answer>=jsonb_array_length(choices) then raise exception 'Answer outside options'; end if;
  insert into public.questions(quiz_id,prompt,options,position) values(target,item->>'prompt',choices,idx) returning id into question_id;
  insert into private.answer_keys(question_id,correct_index,explanation) values(question_id,answer,coalesce(item->>'explanation',''));
  idx:=idx+1;
 end loop;
end $$;
revoke all on function public.owner_quiz_questions(uuid),public.owner_save_questions(uuid,jsonb) from public,anon;
grant execute on function public.owner_quiz_questions(uuid),public.owner_save_questions(uuid,jsonb) to authenticated;
notify pgrst,'reload schema';

commit;

-- 202611070004_owner_security.sql
-- Private tables remain accessible only through authorized SECURITY DEFINER RPCs.
begin;
-- Refuse ambiguous ownership rather than silently removing an administrator.
do $$ begin
 if (select count(*) from private.owners)>1 then
  raise exception 'CURLYmax supports one owner. Select the intended owner in private.owners before applying this migration.';
 end if;
end $$;
create unique index owners_single_administrator on private.owners ((true));
alter table private.owners enable row level security;
alter table private.answer_keys enable row level security;
alter table private.notification_outbox enable row level security;
alter table private.quiz_runs enable row level security;
revoke all on schema private from public, anon, authenticated;
revoke all on private.owners, private.answer_keys, private.notification_outbox, private.quiz_runs from public, anon, authenticated;
revoke create on schema public from public, anon, authenticated;

-- Lock the quiz before validating draft state, serializing edits with publication.
create or replace function public.set_answer_key(question uuid, answer_index int)
returns void language plpgsql security definer set search_path='' as $$
declare target_quiz uuid;
begin
 if not public.is_owner() then raise exception 'Owner only' using errcode='42501'; end if;
 select quiz_id into target_quiz from public.questions where id=question;
 perform 1 from public.quizzes where id=target_quiz and status='draft' for update;
 if not found then raise exception 'Quiz missing or published'; end if;
 if answer_index is null or not exists (
  select 1 from public.questions where id=question and quiz_id=target_quiz
  and answer_index>=0 and answer_index<jsonb_array_length(options)
 ) then raise exception 'Invalid question or answer index'; end if;
 insert into private.answer_keys(question_id,correct_index) values(question,answer_index)
 on conflict(question_id) do update set correct_index=excluded.correct_index;
end $$;
revoke all on function public.set_answer_key(uuid,int) from public,anon;
grant execute on function public.set_answer_key(uuid,int) to authenticated;

-- Apply the same draft restriction to privileged SQL Dashboard edits, and
-- invalidate unfinished runs when grading data changes.
create function private.guard_answer_key() returns trigger
language plpgsql security definer set search_path='' as $$
declare target_quiz uuid; publication_status text;
begin
 select quiz_id into target_quiz from public.questions
 where id=case when tg_op='DELETE' then old.question_id else new.question_id end;
 select status into publication_status from public.quizzes where id=target_quiz for update;
 if publication_status='published' then raise exception 'Unpublish quiz before editing answer keys'; end if;
 if tg_op='UPDATE' and new.question_id<>old.question_id then
  raise exception 'Answer keys cannot be moved to another question';
 end if;
 if tg_op<>'DELETE' and not exists (
  select 1 from public.questions where id=new.question_id
  and new.correct_index>=0 and new.correct_index<jsonb_array_length(options)
 ) then raise exception 'Invalid answer index'; end if;
 delete from private.quiz_runs where quiz_id=target_quiz and attempt_id is null;
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;
create trigger answer_key_guard before insert or update or delete on private.answer_keys
for each row execute function private.guard_answer_key();
revoke all on function private.guard_answer_key() from public,anon,authenticated;
notify pgrst,'reload schema';
commit;
