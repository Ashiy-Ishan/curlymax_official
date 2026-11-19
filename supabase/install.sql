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

-- 202611080005_youtube_sync.sql
-- Public YouTube catalog/metrics; credentials and operational settings stay server-side.
begin;
alter table public.channels add column youtube_channel_id text check(youtube_channel_id ~ '^UC[A-Za-z0-9_-]{22}$');
alter table public.videos
 add column youtube_published_at timestamptz,
 add column view_count bigint check(view_count>=0),
 add column like_count bigint check(like_count>=0),
 add column comment_count bigint check(comment_count>=0),
 add column thumbnail_url text,
 add column metrics_updated_at timestamptz;
create table public.playlists (
 id uuid primary key default gen_random_uuid(),
 channel_id uuid not null references public.channels on delete cascade,
 youtube_playlist_id text not null check(youtube_playlist_id ~ '^[A-Za-z0-9_-]{10,100}$'),
 title text not null, description text not null default '', thumbnail_url text,
 active boolean not null default true, position int not null default 0,
 sync_managed boolean not null default false,
 unique(channel_id,youtube_playlist_id)
);
create table public.playlist_videos (
 playlist_id uuid not null references public.playlists on delete cascade,
 video_id uuid not null references public.videos on delete cascade,
 position int not null check(position>=0), primary key(playlist_id,video_id)
);
create function private.guard_playlist_channel() returns trigger language plpgsql security definer set search_path='' as $$
begin
 if not exists(select 1 from public.playlists p join public.videos v on v.channel_id=p.channel_id where p.id=new.playlist_id and v.id=new.video_id) then
  raise exception 'Playlist and video must belong to the same channel';
 end if;
 return new;
end $$;
create trigger playlist_channel_guard before insert or update on public.playlist_videos for each row execute function private.guard_playlist_channel();
revoke all on function private.guard_playlist_channel() from public,anon,authenticated;
alter table public.playlists enable row level security;
alter table public.playlist_videos enable row level security;
create policy visible_playlists on public.playlists for select to anon,authenticated using (
 public.is_owner() or (active and exists(select 1 from public.channels c where c.id=channel_id and c.active))
);
create policy owner_playlists on public.playlists for all to authenticated using(public.is_owner()) with check(public.is_owner());
create policy visible_playlist_videos on public.playlist_videos for select to anon,authenticated using (
 public.is_owner() or (public.video_visible(video_id) and exists(select 1 from public.playlists p where p.id=playlist_id and p.active))
);
create policy owner_playlist_videos on public.playlist_videos for all to authenticated using(public.is_owner()) with check(public.is_owner());
grant select on public.playlists,public.playlist_videos to anon,authenticated;
grant insert,update,delete on public.playlists,public.playlist_videos to authenticated;

create table private.youtube_sync_settings (
 channel_id uuid primary key references public.channels on delete cascade,
 section_id uuid not null references public.sections,
 enabled boolean not null default false, auto_publish boolean not null default true,
 last_synced_at timestamptz, last_attempted_at timestamptz, last_error text,
 lease uuid, lease_until timestamptz
);
create table private.youtube_video_links (
 channel_id uuid not null references public.channels on delete cascade,
 youtube_video_id text not null check(youtube_video_id ~ '^[A-Za-z0-9_-]{11}$'),
 video_id uuid not null references public.videos on delete cascade,
 primary key(channel_id,youtube_video_id)
);
alter table private.youtube_sync_settings enable row level security;
alter table private.youtube_video_links enable row level security;
revoke all on private.youtube_sync_settings,private.youtube_video_links from public,anon,authenticated;

create function public.owner_youtube_settings() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not public.is_owner() then raise exception 'Owner only' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('channel_id',c.id,'youtube_channel_id',c.youtube_channel_id,
 'section_id',s.section_id,'enabled',coalesce(s.enabled,false),'auto_publish',coalesce(s.auto_publish,true),
 'last_synced_at',s.last_synced_at,'last_error',s.last_error,'running',coalesce(s.lease_until>now(),false)))
 from public.channels c left join private.youtube_sync_settings s on s.channel_id=c.id),'[]'::jsonb);
end $$;
create function public.owner_save_youtube_settings(target uuid,youtube_channel_id text,section_id uuid,enabled boolean,auto_publish boolean)
returns void language plpgsql security definer set search_path='' as $$
declare old_channel text; new_channel text:=nullif(trim(youtube_channel_id),'');
begin
 if not public.is_owner() then raise exception 'Owner only' using errcode='42501'; end if;
 select c.youtube_channel_id into old_channel from public.channels c where c.id=target for update;
 if not found then raise exception 'Channel not found'; end if;
 if new_channel is not null and new_channel !~ '^UC[A-Za-z0-9_-]{22}$' then raise exception 'Use a YouTube UC channel ID or leave blank to resolve the channel handle'; end if;
 if old_channel is distinct from new_channel and exists(select 1 from private.youtube_video_links l where l.channel_id=target) then
  raise exception 'Create a new channel instead of changing an already imported YouTube channel';
 end if;
 if not exists(select 1 from public.sections s where s.id=section_id and s.channel_id=target and s.active) then raise exception 'Choose an active section in this channel'; end if;
 update public.channels c set youtube_channel_id=new_channel where c.id=target;
 insert into private.youtube_sync_settings(channel_id,section_id,enabled,auto_publish) values(target,section_id,enabled,auto_publish)
 on conflict(channel_id) do update set section_id=excluded.section_id,enabled=excluded.enabled,auto_publish=excluded.auto_publish,lease=null,lease_until=null;
end $$;
create function public.owner_youtube_analytics() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not public.is_owner() then raise exception 'Owner only' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(to_jsonb(t)) from (
 select c.id channel_id,count(v.id) video_count,coalesce(sum(v.view_count),0) view_count,
 coalesce(sum(v.like_count),0) like_count,coalesce(sum(v.comment_count),0) comment_count,max(v.metrics_updated_at) last_metrics_at
 from public.channels c left join public.videos v on v.channel_id=c.id group by c.id) t),'[]'::jsonb);
end $$;
revoke all on function public.owner_youtube_settings(),public.owner_save_youtube_settings(uuid,text,uuid,boolean,boolean),public.owner_youtube_analytics() from public,anon;
grant execute on function public.owner_youtube_settings(),public.owner_save_youtube_settings(uuid,text,uuid,boolean,boolean),public.owner_youtube_analytics() to authenticated;

-- Worker entry points are service-role-only; request JWTs never access private tables.
create function public.sync_youtube_targets() returns setof uuid
language sql security definer set search_path='' as $$
 select s.channel_id from private.youtube_sync_settings s join public.channels c on c.id=s.channel_id where s.enabled and c.active order by coalesce(s.last_attempted_at,s.last_synced_at) nulls first,s.channel_id
$$;
create function public.sync_youtube_claim(target uuid,token uuid) returns jsonb
language plpgsql security definer set search_path='' as $$
declare s private.youtube_sync_settings; c public.channels;
begin
 if token is null then raise exception 'Sync token required'; end if;
 select * into c from public.channels where id=target for update;
 if not found or not c.active then return null; end if;
 select * into s from private.youtube_sync_settings where channel_id=target for update;
 if not found or not s.enabled or s.lease_until>now() then return null; end if;
 if not exists(select 1 from public.sections where id=s.section_id and channel_id=target and active) then raise exception 'Sync section unavailable'; end if;
 update private.youtube_sync_settings set lease=token,lease_until=now()+interval '10 minutes',last_attempted_at=now() where channel_id=target;
 return jsonb_build_object('channel_id',target,'youtube_channel_id',c.youtube_channel_id,'handle',c.handle,'section_id',s.section_id,'initial',s.last_synced_at is null);
end $$;
create function public.sync_youtube_fail(target uuid,token uuid,message text) returns void
language sql security definer set search_path='' as $$
 update private.youtube_sync_settings set last_error=left(message,300),lease=null,lease_until=null where channel_id=target and lease=token
$$;

-- Entire channel snapshot commits atomically, after all upstream pages succeed.
create function public.sync_youtube_apply(target uuid,token uuid,resolved_channel text,videos jsonb,playlists jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s private.youtube_sync_settings; c public.channels; item jsonb; p jsonb; member jsonb;
 vid uuid; pid uuid; managed boolean; imported int:=0; initial boolean; upstream_id text;
begin
 if token is null then raise exception 'Sync token required'; end if;
 select * into c from public.channels where id=target for update;
 select * into s from private.youtube_sync_settings where channel_id=target for update;
 if not found or s.lease is null or s.lease_until is null or s.lease is distinct from token or s.lease_until<=now() or not s.enabled or not c.active then raise exception 'Sync lease expired or settings changed'; end if;
 if resolved_channel is null or resolved_channel !~ '^UC[A-Za-z0-9_-]{22}$' or (c.youtube_channel_id is not null and c.youtube_channel_id<>resolved_channel) then raise exception 'Channel mismatch'; end if;
 if jsonb_typeof(videos) is distinct from 'array' or jsonb_array_length(videos)>1000 or jsonb_typeof(playlists) is distinct from 'array' or jsonb_array_length(playlists)>50 then raise exception 'Invalid sync snapshot'; end if;
 if not exists(select 1 from public.sections where id=s.section_id and channel_id=target and active) then raise exception 'Sync section unavailable'; end if;
 initial:=s.last_synced_at is null;
 update public.channels set youtube_channel_id=resolved_channel where id=target;
 for item in select value from jsonb_array_elements(videos) loop
  upstream_id:=item->>'id';
  if upstream_id is null or upstream_id !~ '^[A-Za-z0-9_-]{11}$' or item->>'channel_id' is distinct from resolved_channel then raise exception 'Invalid video channel or ID'; end if;
  select video_id into vid from private.youtube_video_links where channel_id=target and youtube_video_id=upstream_id;
  if vid is null then
   select id into vid from public.videos where channel_id=target and youtube_id=upstream_id order by created_at,id limit 1;
   if vid is null then
    insert into public.videos(channel_id,section_id,title,description,youtube_url,status)
    values(target,s.section_id,left(item->>'title',500),left(coalesce(item->>'description',''),20000),'https://www.youtube.com/watch?v='||upstream_id,'draft') returning id into vid;
    -- Initial backfill is draft regardless of automatic publication preference.
    if s.auto_publish and not initial then
     update public.videos set status='published' where id=vid;
    end if;
    imported:=imported+1;
   end if;
   insert into private.youtube_video_links(channel_id,youtube_video_id,video_id) values(target,upstream_id,vid);
  end if;
  update public.videos set youtube_published_at=(item->>'published_at')::timestamptz,
   view_count=(item->>'view_count')::bigint,like_count=(item->>'like_count')::bigint,comment_count=(item->>'comment_count')::bigint,
   thumbnail_url=case when item->>'thumbnail_url' ~ '^https://i[.]ytimg[.]com/' then item->>'thumbnail_url' else null end,
   metrics_updated_at=now() where id=vid;
 end loop;
 for p in select value from jsonb_array_elements(playlists) loop
  if jsonb_typeof(p->'video_ids') is distinct from 'array' or jsonb_array_length(p->'video_ids')>1000 then raise exception 'Invalid playlist members'; end if;
  insert into public.playlists(channel_id,youtube_playlist_id,title,description,thumbnail_url,sync_managed)
  values(target,p->>'id',left(p->>'title',500),left(coalesce(p->>'description',''),20000),case when p->>'thumbnail_url' ~ '^https://i[.]ytimg[.]com/' then p->>'thumbnail_url' else null end,true)
  on conflict(channel_id,youtube_playlist_id) do update set youtube_playlist_id=excluded.youtube_playlist_id returning id,sync_managed into pid,managed;
  -- Existing metadata/visibility are owner-owned. Manual playlists opt out.
  if not managed then continue; end if;
  delete from public.playlist_videos where playlist_id=pid;
  insert into public.playlist_videos(playlist_id,video_id,position)
  select pid,l.video_id,min((x.ordinality-1)::int) from jsonb_array_elements_text(p->'video_ids') with ordinality x(value,ordinality)
   join private.youtube_video_links l on l.channel_id=target and l.youtube_video_id=x.value group by l.video_id;
 end loop;
 -- Upstream-deleted playlists no longer expose stale membership. Keep the row
 -- and owner visibility choice, but clear memberships from this full snapshot.
 delete from public.playlist_videos pv using public.playlists p where pv.playlist_id=p.id and p.channel_id=target and p.sync_managed
  and not exists(select 1 from jsonb_array_elements(playlists) x where x->>'id'=p.youtube_playlist_id);
 update private.youtube_sync_settings set last_synced_at=now(),last_error=null,lease=null,lease_until=null where channel_id=target;
 return jsonb_build_object('channel_id',target,'imported',imported,'videos',jsonb_array_length(videos),'playlists',jsonb_array_length(playlists),'initial',initial);
end $$;
revoke all on function public.sync_youtube_targets(),public.sync_youtube_claim(uuid,uuid),public.sync_youtube_fail(uuid,uuid,text),public.sync_youtube_apply(uuid,uuid,text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.sync_youtube_targets(),public.sync_youtube_claim(uuid,uuid),public.sync_youtube_fail(uuid,uuid,text),public.sync_youtube_apply(uuid,uuid,text,jsonb,jsonb) to service_role;
alter publication supabase_realtime add table public.playlists,public.playlist_videos;
notify pgrst,'reload schema';
commit;

-- Account deletion uses Auth Admin on the server, with caller identity verified
-- by the delete-account function. Cascades remove only that user's private rows.
begin;
alter table public.channels add column avatar_url text
 check(avatar_url is null or (length(avatar_url)<=2048 and avatar_url ~ '^https://[^[:space:]]+$'));
alter table private.owners drop constraint owners_user_id_fkey;
alter table private.owners add constraint owners_user_id_fkey
 foreign key(user_id) references auth.users(id) on delete cascade;
notify pgrst,'reload schema';
commit;

-- 202611080007_automatic_youtube_import.sql
-- Automatically publish new public YouTube imports, including initial backfill.
-- Existing catalog drafts and quiz publication remain entirely owner-controlled.
begin;
create or replace function public.sync_youtube_apply(target uuid,token uuid,resolved_channel text,videos jsonb,playlists jsonb)
returns jsonb language plpgsql security definer set search_path='' as $$
declare s private.youtube_sync_settings; c public.channels; item jsonb; p jsonb; member jsonb;
 vid uuid; pid uuid; managed boolean; imported int:=0; initial boolean; upstream_id text;
begin
 if token is null then raise exception 'Sync token required'; end if;
 select * into c from public.channels where id=target for update;
 select * into s from private.youtube_sync_settings where channel_id=target for update;
 if not found or s.lease is null or s.lease_until is null or s.lease is distinct from token or s.lease_until<=now() or not s.enabled or not c.active then raise exception 'Sync lease expired or settings changed'; end if;
 if resolved_channel is null or resolved_channel !~ '^UC[A-Za-z0-9_-]{22}$' or (c.youtube_channel_id is not null and c.youtube_channel_id<>resolved_channel) then raise exception 'Channel mismatch'; end if;
 if jsonb_typeof(videos) is distinct from 'array' or jsonb_array_length(videos)>1000 or jsonb_typeof(playlists) is distinct from 'array' or jsonb_array_length(playlists)>50 then raise exception 'Invalid sync snapshot'; end if;
 if not exists(select 1 from public.sections where id=s.section_id and channel_id=target and active) then raise exception 'Sync section unavailable'; end if;
 initial:=s.last_synced_at is null;
 update public.channels set youtube_channel_id=resolved_channel where id=target;
 for item in select value from jsonb_array_elements(videos) loop
  upstream_id:=item->>'id';
  if upstream_id is null or upstream_id !~ '^[A-Za-z0-9_-]{11}$' or item->>'channel_id' is distinct from resolved_channel then raise exception 'Invalid video channel or ID'; end if;
  select video_id into vid from private.youtube_video_links where channel_id=target and youtube_video_id=upstream_id;
  if vid is null then
   select id into vid from public.videos where channel_id=target and youtube_id=upstream_id order by created_at,id limit 1;
   if vid is null then
    insert into public.videos(channel_id,section_id,title,description,youtube_url,status)
    values(target,s.section_id,left(item->>'title',500),left(coalesce(item->>'description',''),20000),'https://www.youtube.com/watch?v='||upstream_id,'draft') returning id into vid;
    -- Public YouTube imports are immediately visible when automatic publication
    -- is enabled, including the first import. Only brand-new rows reach here;
    -- manual drafts and owner-unpublished existing rows are never promoted.
    if s.auto_publish then
     update public.videos set status='published' where id=vid;
     -- Silence old backfill videos atomically. The worker cannot observe this
     -- uncommitted event. No session flag or global trigger bypass is used.
     if initial then
      delete from private.notification_outbox where kind='video' and item_id=vid;
     end if;
    end if;
    imported:=imported+1;
   end if;
   insert into private.youtube_video_links(channel_id,youtube_video_id,video_id) values(target,upstream_id,vid);
  end if;
  update public.videos set youtube_published_at=(item->>'published_at')::timestamptz,
   view_count=(item->>'view_count')::bigint,like_count=(item->>'like_count')::bigint,comment_count=(item->>'comment_count')::bigint,
   thumbnail_url=case when item->>'thumbnail_url' ~ '^https://i[.]ytimg[.]com/' then item->>'thumbnail_url' else null end,
   metrics_updated_at=now() where id=vid;
 end loop;
 for p in select value from jsonb_array_elements(playlists) loop
  if jsonb_typeof(p->'video_ids') is distinct from 'array' or jsonb_array_length(p->'video_ids')>1000 then raise exception 'Invalid playlist members'; end if;
  insert into public.playlists(channel_id,youtube_playlist_id,title,description,thumbnail_url,sync_managed)
  values(target,p->>'id',left(p->>'title',500),left(coalesce(p->>'description',''),20000),case when p->>'thumbnail_url' ~ '^https://i[.]ytimg[.]com/' then p->>'thumbnail_url' else null end,true)
  on conflict(channel_id,youtube_playlist_id) do update set youtube_playlist_id=excluded.youtube_playlist_id returning id,sync_managed into pid,managed;
  -- Existing metadata/visibility are owner-owned. Manual playlists opt out.
  if not managed then continue; end if;
  delete from public.playlist_videos where playlist_id=pid;
  insert into public.playlist_videos(playlist_id,video_id,position)
  select pid,l.video_id,min((x.ordinality-1)::int) from jsonb_array_elements_text(p->'video_ids') with ordinality x(value,ordinality)
   join private.youtube_video_links l on l.channel_id=target and l.youtube_video_id=x.value group by l.video_id;
 end loop;
 -- Upstream-deleted playlists no longer expose stale membership. Keep the row
 -- and owner visibility choice, but clear memberships from this full snapshot.
 delete from public.playlist_videos pv using public.playlists p where pv.playlist_id=p.id and p.channel_id=target and p.sync_managed
  and not exists(select 1 from jsonb_array_elements(playlists) x where x->>'id'=p.youtube_playlist_id);
 update private.youtube_sync_settings set last_synced_at=now(),last_error=null,lease=null,lease_until=null where channel_id=target;
 return jsonb_build_object('channel_id',target,'imported',imported,'videos',jsonb_array_length(videos),'playlists',jsonb_array_length(playlists),'initial',initial);
end $$;
revoke all on function public.sync_youtube_apply(uuid,uuid,text,jsonb,jsonb) from public,anon,authenticated;
grant execute on function public.sync_youtube_apply(uuid,uuid,text,jsonb,jsonb) to service_role;
-- One owner-only transaction creates the initial question and private key.
-- Further editing and publishing continue through the existing draft workflow.
create function public.owner_create_quiz(video_id uuid,title text,question jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare quiz_id uuid; clean_title text:=trim(title); prompt text; choices jsonb; feedback text;
begin
 if not public.is_owner() then raise exception 'Owner only' using errcode='42501'; end if;
 if clean_title is null or length(clean_title)=0 or length(clean_title)>500 then raise exception 'Enter a quiz title of 1 to 500 characters'; end if;
 if jsonb_typeof(question) is distinct from 'object' then raise exception 'Provide a question'; end if;
 if question->'prompt' is not null and question->'prompt'<>'null'::jsonb and jsonb_typeof(question->'prompt')<>'string' then raise exception 'Question prompt must be text'; end if;
 if question->'explanation' is not null and question->'explanation'<>'null'::jsonb and jsonb_typeof(question->'explanation')<>'string' then raise exception 'Explanation must be text'; end if;
 prompt:=coalesce(nullif(trim(question->>'prompt'),''),clean_title);
 feedback:=coalesce(trim(question->>'explanation'),'');
 choices:=question->'options';
 if jsonb_typeof(choices) is distinct from 'array' then raise exception 'Provide two to four answer options'; end if;
 if jsonb_array_length(choices) not between 2 and 4 or exists(select 1 from jsonb_array_elements(choices) x where jsonb_typeof(x)<>'string' or length(trim(x #>> '{}'))=0) then raise exception 'Provide two to four nonempty text options'; end if;
 select jsonb_agg(trim(x.value #>> '{}') order by x.ordinality) into choices from jsonb_array_elements(choices) with ordinality x(value,ordinality);
 if coalesce(question->>'correct_index','') !~ '^[0-3]$' or (question->>'correct_index')::int>=jsonb_array_length(choices) then raise exception 'Choose a valid correct answer'; end if;
 insert into public.quizzes(video_id,title,status) values(video_id,clean_title,'draft') returning id into quiz_id;
 perform public.owner_save_questions(quiz_id,jsonb_build_array(jsonb_build_object('prompt',prompt,'options',choices,'correct_index',(question->>'correct_index')::int,'explanation',feedback)));
 return quiz_id;
end $$;
revoke all on function public.owner_create_quiz(uuid,text,jsonb) from public,anon;
grant execute on function public.owner_create_quiz(uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;

-- 202611080008_youtube_channel_avatar.sql
-- Keep owner override separate from the automatically refreshed YouTube logo.
begin;
alter table public.channels add column youtube_avatar_url text
 check(youtube_avatar_url is null or (length(youtube_avatar_url)<=2048 and youtube_avatar_url ~ '^https://(yt3[.]ggpht[.]com|yt3[.]googleusercontent[.]com|i[.]ytimg[.]com)/[^[:space:][:cntrl:]]*$'));
create function public.sync_youtube_channel_avatar(target uuid,resolved_channel text,logo_url text)
returns void language plpgsql security definer set search_path='' as $$
begin
 -- Lock and recheck the source identity after catalog synchronization. A stale
 -- worker must not attach another YouTube channel's logo after an owner edit.
 perform 1 from public.channels c where c.id=target and c.active
  and resolved_channel ~ '^UC[A-Za-z0-9_-]{22}$' and c.youtube_channel_id=resolved_channel for update;
 if not found then raise exception 'YouTube channel mismatch or unavailable'; end if;
 -- Missing provider thumbnail does not erase the previous valid source logo.
 if logo_url is null then return; end if;
 if length(logo_url)>2048 or logo_url !~ '^https://(yt3[.]ggpht[.]com|yt3[.]googleusercontent[.]com|i[.]ytimg[.]com)/[^[:space:][:cntrl:]]*$' then
  raise exception 'Use a valid HTTPS YouTube thumbnail URL';
 end if;
 -- Older installed clients only read avatar_url. Refresh its automatic copy
 -- when empty or still equal to the previous source; preserve manual overrides.
 update public.channels set
  avatar_url=case when nullif(trim(avatar_url),'') is null or avatar_url=youtube_avatar_url then logo_url else avatar_url end,
  youtube_avatar_url=logo_url
 where id=target;
end $$;
revoke all on function public.sync_youtube_channel_avatar(uuid,text,text) from public,anon,authenticated;
grant execute on function public.sync_youtube_channel_avatar(uuid,text,text) to service_role;
notify pgrst,'reload schema';
commit;

-- 202611190009_release_security.sql
-- Additive release hardening; existing catalog and private records are retained.
begin;
create index if not exists notes_owner_updated on public.notes(user_id,updated_at desc);
create index if not exists attempts_owner_submitted on public.attempts(user_id,submitted_at desc);
create index if not exists quiz_runs_owner_created on private.quiz_runs(user_id,created_at desc);
create index if not exists outbox_pending_created on private.notification_outbox(created_at) where state='pending';

create table private.write_limits (
 user_id uuid not null references auth.users(id) on delete cascade,
 action text not null, window_started timestamptz not null, hits int not null,
 primary key(user_id,action)
);
alter table private.write_limits enable row level security;
revoke all on private.write_limits from public,anon,authenticated;
create function private.limit_user_writes() returns trigger
language plpgsql security definer set search_path='' as $$
declare actor uuid:=auth.uid(); bucket text:=tg_table_name; ceiling int; used int;
begin
 if actor is not null then
  ceiling:=case bucket when 'notes' then 60 when 'quiz_runs' then 20 else 60 end;
  insert into private.write_limits(user_id,action,window_started,hits) values(actor,bucket,clock_timestamp(),1)
  on conflict(user_id,action) do update set
   hits=case when private.write_limits.window_started < clock_timestamp()-interval '1 minute' then 1 else private.write_limits.hits+1 end,
   window_started=case when private.write_limits.window_started < clock_timestamp()-interval '1 minute' then clock_timestamp() else private.write_limits.window_started end
  returning hits into used;
  if used>ceiling then raise exception 'Too many requests. Wait a minute and retry.' using errcode='P0001'; end if;
 end if;
 if tg_op='DELETE' then return old; end if;
 return new;
end $$;
create trigger note_write_limit before insert or update on public.notes for each row execute function private.limit_user_writes();
create trigger run_write_limit before insert on private.quiz_runs for each row execute function private.limit_user_writes();
create trigger attempt_write_limit before insert on public.attempts for each row execute function private.limit_user_writes();
revoke all on function private.limit_user_writes() from public,anon,authenticated;

alter table private.notification_outbox add column attempt_count int not null default 0,
 add column last_attempt_at timestamptz;
create or replace function public.claim_notifications() returns setof private.notification_outbox
language sql security definer set search_path='' as $$
 update private.notification_outbox o set state='dispatching',dispatched_at=now(),
  attempt_count=o.attempt_count+1,last_attempt_at=now()
 where o.id in (
  select n.id from private.notification_outbox n where n.state='pending'
   and ((n.kind='video' and public.video_visible(n.item_id)) or (n.kind='quiz' and public.quiz_visible(n.item_id)))
  order by n.created_at for update skip locked limit 5
 ) returning o.*
$$;
create function public.notification_ready(event uuid) returns jsonb
language sql security definer set search_path='' as $$
 select to_jsonb(n) from private.notification_outbox n where n.id=event and n.state='dispatching'
 and ((n.kind='video' and public.video_visible(n.item_id)) or (n.kind='quiz' and public.quiz_visible(n.item_id)))
$$;
revoke all on function public.notification_ready(uuid),public.claim_notifications() from public,anon,authenticated;
grant execute on function public.notification_ready(uuid),public.claim_notifications() to service_role;

create table public.notifications (
 id uuid primary key references private.notification_outbox(id) on delete cascade,
 kind text not null check(kind in ('video','quiz')), item_id uuid not null,
 title text not null, created_at timestamptz not null default now()
);
alter table public.notifications enable row level security;
create policy notification_publication_visible on public.notifications for select to anon,authenticated
 using((kind='video' and public.video_visible(item_id)) or (kind='quiz' and public.quiz_visible(item_id)));
revoke all on public.notifications from public,anon,authenticated;
grant select on public.notifications to anon,authenticated;
create table public.notification_reads (
 notification_id uuid not null references public.notifications(id) on delete cascade,
 user_id uuid not null references auth.users(id) on delete cascade,
 read_at timestamptz not null default now(), primary key(user_id,notification_id)
);
alter table public.notification_reads enable row level security;
create policy notification_reads_own on public.notification_reads for select to authenticated using(user_id=auth.uid());
revoke all on public.notification_reads from public,anon,authenticated;
grant select on public.notification_reads to authenticated;
create function private.record_notification() returns trigger
language plpgsql security definer set search_path='' as $$
begin
 insert into public.notifications(id,kind,item_id,title,created_at) values(new.id,new.kind,new.item_id,new.title,new.created_at);
 return new;
end $$;
revoke all on function private.record_notification() from public,anon,authenticated;
create trigger outbox_record_notification after insert on private.notification_outbox for each row execute function private.record_notification();
insert into public.notifications(id,kind,item_id,title,created_at) select id,kind,item_id,title,created_at from private.notification_outbox;
create function public.mark_notification_read(event uuid) returns void
language plpgsql security definer set search_path='' as $$
begin
 if auth.uid() is null then raise exception 'Sign in required' using errcode='42501'; end if;
 if not exists(select 1 from public.notifications n where n.id=event and
  ((n.kind='video' and public.video_visible(n.item_id)) or (n.kind='quiz' and public.quiz_visible(n.item_id)))) then
  raise exception 'Notification unavailable' using errcode='42501';
 end if;
 insert into public.notification_reads(notification_id,user_id) values(event,auth.uid()) on conflict do nothing;
end $$;
revoke all on function public.mark_notification_read(uuid) from public,anon;
grant execute on function public.mark_notification_read(uuid) to authenticated;
create or replace function public.owner_notification_status() returns jsonb
language plpgsql security definer set search_path='' as $$
begin
 if not public.is_owner() then raise exception 'Owner only' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(to_jsonb(t)) from
  (select id,kind,item_id,title,state,created_at,dispatched_at,detail,attempt_count,last_attempt_at
   from private.notification_outbox order by created_at desc limit 100) t),'[]'::jsonb);
end $$;
revoke all on function public.owner_notification_status() from public,anon;
grant execute on function public.owner_notification_status() to authenticated;
alter publication supabase_realtime add table public.notifications,public.notification_reads;
notify pgrst,'reload schema';
commit;
