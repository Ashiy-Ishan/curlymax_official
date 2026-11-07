-- Add to the existing project once; no answer key becomes readable by viewers.
begin;
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
