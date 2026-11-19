-- Isolated fixture only; runs before the original quiz is edited/unpublished.
insert into auth.users(id) values ('dddddddd-dddd-dddd-dddd-dddddddddddd'),('eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee');
-- A draft must not appear in either the private queue or the public inbox.
insert into public.quizzes(id,video_id,title,status) values ('33333333-3333-3333-3333-333333333333','11111111-1111-1111-1111-111111111111','Notification draft','draft');
do $$ begin
 if exists(select 1 from private.notification_outbox where item_id='33333333-3333-3333-3333-333333333333') or exists(select 1 from public.notifications where item_id='33333333-3333-3333-3333-333333333333') then raise exception 'Draft generated notification'; end if;
 begin update public.quizzes set status='published' where id='33333333-3333-3333-3333-333333333333'; raise exception 'Empty quiz published';
 exception when raise_exception then if sqlerrm <> 'Every quiz needs questions and valid answer keys' then raise; end if; end;
end $$;
-- A first publication creates one event. Metadata updates and re-publication do not duplicate it.
insert into public.questions(id,quiz_id,prompt,options,position) values ('33333333-3333-3333-3333-333333333334','33333333-3333-3333-3333-333333333333','Test?','["A","B"]',0);
insert into private.answer_keys(question_id,correct_index) values ('33333333-3333-3333-3333-333333333334',0);
update public.quizzes set status='published' where id='33333333-3333-3333-3333-333333333333';
update public.quizzes set title='Metadata update' where id='33333333-3333-3333-3333-333333333333';
update public.quizzes set status='draft' where id='33333333-3333-3333-3333-333333333333';
set role anon; set request.jwt.claim.sub='';
do $$ begin
 if exists(select 1 from public.notifications where item_id='33333333-3333-3333-3333-333333333333') then raise exception 'Guest saw unpublished announcement'; end if;
 begin perform public.mark_notification_read(gen_random_uuid()); raise exception 'Guest marked read'; exception when insufficient_privilege then null; end;
 begin perform public.notification_ready(gen_random_uuid()); raise exception 'Guest accessed dispatch readiness'; exception when insufficient_privilege then null; end;
end $$;
reset role;
update public.quizzes set status='published' where id='33333333-3333-3333-3333-333333333333';
do $$ begin
 if (select count(*) from private.notification_outbox where item_id='33333333-3333-3333-3333-333333333333')<>1 or (select count(*) from public.notifications where item_id='33333333-3333-3333-3333-333333333333')<>1 then raise exception 'Publication duplicated'; end if;
end $$;
set role authenticated; set request.jwt.claim.sub='dddddddd-dddd-dddd-dddd-dddddddddddd';
do $$ declare event_id uuid; begin
 select id into event_id from public.notifications where item_id='33333333-3333-3333-3333-333333333333';
 perform public.mark_notification_read(event_id); perform public.mark_notification_read(event_id);
 if (select count(*) from public.notification_reads)<>1 then raise exception 'Duplicate read receipt'; end if;
 begin insert into public.notification_reads(notification_id,user_id) values(event_id,'eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee'); raise exception 'Forged receipt accepted'; exception when insufficient_privilege then null; end;
 begin perform public.notification_ready(event_id); raise exception 'Viewer accessed dispatch readiness'; exception when insufficient_privilege then null; end;
 begin perform public.owner_notification_status(); raise exception 'Viewer accessed owner queue'; exception when insufficient_privilege then null; end;
end $$;
set request.jwt.claim.sub='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
do $$ declare event_id uuid; begin
 if exists(select 1 from public.notification_reads) then raise exception 'Cross-user read receipt visible'; end if;
 select id into event_id from public.notifications where item_id='33333333-3333-3333-3333-333333333333';
 perform public.mark_notification_read(event_id);
 if (select count(*) from public.notification_reads)<>1 then raise exception 'Independent user receipt failed'; end if;
end $$;
reset role;
-- At least seven visible queued videos ensure claim batch is meaningfully bounded.
insert into public.videos(channel_id,section_id,title,youtube_url,status)
select '10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Batch fixture '||i,'https://youtu.be/fq4N0hgOWzU','published' from generate_series(1,7) i;
set role service_role;
do $$ declare claimed private.notification_outbox; n int:=0; begin
 for claimed in select * from public.claim_notifications() loop
  n:=n+1;
  if claimed.attempt_count<>1 or claimed.last_attempt_at is null then raise exception 'Claim attempt not recorded'; end if;
  if public.notification_ready(claimed.id) is null then raise exception 'Visible claimed event not ready'; end if;
 end loop;
 if n<>5 then raise exception 'Claim batch must contain exactly five with available backlog, got %',n; end if;
end $$;
reset role;
-- Visibility is checked again after claiming, before sending.
update public.videos set status='draft' where id in (select item_id from private.notification_outbox where state='dispatching' and kind='video');
set role service_role;
do $$ declare e private.notification_outbox; begin
 for e in select * from public.claim_notifications() loop
  if e.attempt_count<>1 then raise exception 'Previously dispatched event reclaimed'; end if;
 end loop;
end $$;
reset role;
do $$ declare event_id uuid; begin
 select id into event_id from private.notification_outbox where state='dispatching' and kind='video' and not public.video_visible(item_id) limit 1;
 if event_id is null then raise exception 'Expected hidden claimed fixture'; end if;
 if public.notification_ready(event_id) is not null then raise exception 'Hidden event still ready'; end if;
 perform public.finish_notification(event_id,false,'FCM test failure');
 perform public.finish_notification(event_id,true,'Duplicate completion must not overwrite');
 if not exists(select 1 from private.notification_outbox where id=event_id and state='failed' and detail='FCM test failure' and attempt_count=1) then raise exception 'Failed outcome not retained'; end if;
end $$;
-- Restore only the pre-existing fixture video needed by remaining tests.
update public.videos set status='published' where id='11111111-1111-1111-1111-111111111111';
set role authenticated; set request.jwt.claim.sub='dddddddd-dddd-dddd-dddd-dddddddddddd';
do $$ declare i int; begin
 for i in 1..20 loop perform public.start_quiz_run('22222222-2222-2222-2222-222222222222'); end loop;
 begin perform public.start_quiz_run('22222222-2222-2222-2222-222222222222'); raise exception '21st run allowed';
 exception when raise_exception then if sqlerrm <> 'Too many requests. Wait a minute and retry.' then raise; end if; end;
end $$;
set request.jwt.claim.sub='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
select public.start_quiz_run('22222222-2222-2222-2222-222222222222');
reset role;
do $$ begin
 if (select count(*) from private.quiz_runs where user_id='dddddddd-dddd-dddd-dddd-dddddddddddd')<>20 then raise exception 'Run limiter count incorrect'; end if;
 if (select count(*) from private.quiz_runs where user_id='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee')<>1 then raise exception 'Another user quota affected'; end if;
end $$;
-- An expired window permits another run without deleting rate-limit history.
update private.write_limits set window_started=clock_timestamp()-interval '61 seconds' where user_id='dddddddd-dddd-dddd-dddd-dddddddddddd' and action='quiz_runs';
set role authenticated; set request.jwt.claim.sub='dddddddd-dddd-dddd-dddd-dddddddddddd';
select public.start_quiz_run('22222222-2222-2222-2222-222222222222');
reset role;
-- Notes and the legacy submission endpoint share the same per-user abuse boundary.
set role authenticated; set request.jwt.claim.sub='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee';
do $$ declare i int; answers jsonb; begin
 for i in 1..60 loop insert into public.notes(video_id,body) values('11111111-1111-1111-1111-111111111111','Quota fixture'); end loop;
 begin insert into public.notes(video_id,body) values('11111111-1111-1111-1111-111111111111','Over quota'); raise exception '61st note allowed';
 exception when raise_exception then if sqlerrm <> 'Too many requests. Wait a minute and retry.' then raise; end if; end;
 select jsonb_object_agg(id::text,0) into answers from public.questions where quiz_id='22222222-2222-2222-2222-222222222222';
 for i in 1..60 loop perform public.submit_quiz('22222222-2222-2222-2222-222222222222',answers); end loop;
 begin perform public.submit_quiz('22222222-2222-2222-2222-222222222222',answers); raise exception '61st legacy attempt allowed';
 exception when raise_exception then if sqlerrm <> 'Too many requests. Wait a minute and retry.' then raise; end if; end;
end $$;
reset role;
-- Cascade deletes only these disposable fixture accounts' receipts and quota state.
delete from auth.users where id='dddddddd-dddd-dddd-dddd-dddddddddddd';
do $$ begin
 if exists(select 1 from public.notification_reads where user_id='dddddddd-dddd-dddd-dddd-dddddddddddd') or exists(select 1 from private.write_limits where user_id='dddddddd-dddd-dddd-dddd-dddddddddddd') then raise exception 'Deleted account retained receipts/quotas'; end if;
 if not exists(select 1 from public.notification_reads where user_id='eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee') then raise exception 'Other account receipt deleted'; end if;
end $$;
set request.jwt.claim.sub='';
select 'PASS: publication deduplication/draft denial, private read receipts, bounded service-only claims, failure outcome, user-isolated run quotas/window reset and account cascade' as result;
