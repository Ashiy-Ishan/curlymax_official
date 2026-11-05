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
