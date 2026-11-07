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
