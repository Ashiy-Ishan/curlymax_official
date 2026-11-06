-- Run ONCE in the existing CURLYmax project's SQL Editor. No catalog reset.
begin;
create or replace function public.owner_quiz_questions(target uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.is_owner() then raise exception 'Owner only' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(jsonb_build_object('id',q.id,'prompt',q.prompt,'options',q.options,'correct_index',k.correct_index) order by q.position)
 from public.questions q left join private.answer_keys k on k.question_id=q.id where q.quiz_id=target),'[]'::jsonb);
end $$;
-- Transactional question editor: failed validation rolls back the whole edit.
create or replace function public.owner_save_questions(target uuid, items jsonb)
returns void language plpgsql security definer set search_path='' as $$
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
  insert into private.answer_keys values(question_id,answer);
  idx:=idx+1;
 end loop;
end $$;
create or replace function public.owner_notification_status()
returns jsonb language plpgsql security definer set search_path='' as $$
begin
 if not public.is_owner() then raise exception 'Owner only' using errcode='42501'; end if;
 return coalesce((select jsonb_agg(to_jsonb(t)) from
 (select id,kind,item_id,title,state,created_at,dispatched_at,detail from private.notification_outbox order by created_at desc limit 100) t),'[]'::jsonb);
end $$;
revoke all on function public.owner_quiz_questions(uuid),public.owner_save_questions(uuid,jsonb),public.owner_notification_status() from public,anon;
grant execute on function public.owner_quiz_questions(uuid),public.owner_save_questions(uuid,jsonb),public.owner_notification_status() to authenticated;
commit;
