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
