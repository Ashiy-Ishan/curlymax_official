-- After quiz_feedback.sql fixtures, only in the isolated test database.
insert into public.videos(id,channel_id,section_id,title,youtube_url,status) values
 ('55555555-5555-5555-5555-555555555555','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Owner draft','https://youtu.be/manual00001','draft');
insert into public.quizzes(id,video_id,title,status) values ('44444444-4444-4444-4444-444444444444','11111111-1111-1111-1111-111111111111','Owner review required','draft');
create temporary table quizzes_before_sync as select id,status,title from public.quizzes;
set role anon;
set request.jwt.claim.sub='';
do $$ begin
 begin perform public.owner_youtube_settings(); raise exception 'Guest read sync settings'; exception when insufficient_privilege then null; end;
 begin perform public.sync_youtube_targets(); raise exception 'Guest scheduled sync'; exception when insufficient_privilege then null; end;
end $$;
reset role;
set role authenticated;
set request.jwt.claim.sub='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
do $$ begin
 begin perform public.owner_youtube_analytics(); raise exception 'Viewer read admin analytics'; exception when insufficient_privilege then null; end;
 begin perform public.owner_save_youtube_settings('10000000-0000-0000-0000-000000000001',null,'20000000-0000-0000-0000-000000000001',true,true); raise exception 'Viewer changed sync settings'; exception when insufficient_privilege then null; end;
 begin perform public.sync_youtube_claim('10000000-0000-0000-0000-000000000001',gen_random_uuid()); raise exception 'Viewer claimed sync'; exception when insufficient_privilege then null; end;
end $$;
set request.jwt.claim.sub='cccccccc-cccc-cccc-cccc-cccccccccccc';
select public.owner_save_youtube_settings('10000000-0000-0000-0000-000000000001',null,'20000000-0000-0000-0000-000000000001',true,true);
reset role;
set role service_role;
do $$ declare claimed jsonb; begin
 claimed:=public.sync_youtube_claim('10000000-0000-0000-0000-000000000001','dddddddd-dddd-dddd-dddd-dddddddddddd');
 if not (claimed->>'initial')::boolean then raise exception 'Initial claim failed'; end if;
 if public.sync_youtube_claim('10000000-0000-0000-0000-000000000001',gen_random_uuid()) is not null then raise exception 'Overlapping sync allowed'; end if;
 perform public.sync_youtube_apply('10000000-0000-0000-0000-000000000001','dddddddd-dddd-dddd-dddd-dddddddddddd','UCabcdefghijklmnopqrstuv',
 '[{"id":"fq4N0hgOWzU","channel_id":"UCabcdefghijklmnopqrstuv","title":"Overwrite attempt","view_count":"20"},{"id":"newvideo001","channel_id":"UCabcdefghijklmnopqrstuv","title":"Initial import","view_count":"10"},{"id":"manual00001","channel_id":"UCabcdefghijklmnopqrstuv","title":"Do not publish manual draft"}]',
 '[{"id":"PL1234567890","title":"Playlist","video_ids":["fq4N0hgOWzU","newvideo001"]}]');
end $$;
reset role;
do $$ begin
 if not exists(select 1 from public.videos where youtube_id='newvideo001' and status='published') then raise exception 'Initial import was not published'; end if;
 if not exists(select 1 from public.videos where youtube_id='fq4N0hgOWzU' and title='Quiz fixture' and status='published' and view_count=20) then raise exception 'Manual metadata changed'; end if;
 if exists(select 1 from private.notification_outbox o join public.videos v on v.id=o.item_id where v.youtube_id='newvideo001') then raise exception 'Initial import alert'; end if;
end $$;
set role anon;
set request.jwt.claim.sub='';
do $$ begin
 if (select count(*) from public.playlist_videos)<>2 then raise exception 'Guest cannot see imported playlist membership'; end if;
 if not exists(select 1 from public.videos where youtube_id='newvideo001') then raise exception 'Guest cannot see initial import'; end if;
 if exists(select 1 from public.videos where youtube_id='manual00001') then raise exception 'Manual draft exposed'; end if;
end $$;
reset role;
-- Explicit owner unpublishing must be preserved on all later synchronization.
update public.videos set status='draft' where youtube_id='newvideo001';
set role service_role;
select public.sync_youtube_claim('10000000-0000-0000-0000-000000000001','eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee');
select public.sync_youtube_apply('10000000-0000-0000-0000-000000000001','eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee','UCabcdefghijklmnopqrstuv',
 '[{"id":"newvideo001","channel_id":"UCabcdefghijklmnopqrstuv","title":"Do not overwrite draft"},{"id":"newvideo002","channel_id":"UCabcdefghijklmnopqrstuv","title":"New upload","view_count":"200"}]','[]');
reset role;
do $$ begin
 if not exists(select 1 from public.videos where youtube_id='newvideo001' and title='Initial import' and status='draft') then raise exception 'Existing draft auto-published'; end if;
 if not exists(select 1 from public.videos where youtube_id='newvideo002' and status='published') then raise exception 'Later upload not published'; end if;
 if (select count(*) from private.notification_outbox o join public.videos v on v.id=o.item_id where v.youtube_id='newvideo002')<>1 then raise exception 'New upload alert missing or duplicated'; end if;
end $$;
set role service_role;
select public.sync_youtube_claim('10000000-0000-0000-0000-000000000001','ffffffff-ffff-ffff-ffff-ffffffffffff');
select public.sync_youtube_apply('10000000-0000-0000-0000-000000000001','ffffffff-ffff-ffff-ffff-ffffffffffff','UCabcdefghijklmnopqrstuv','[{"id":"newvideo002","channel_id":"UCabcdefghijklmnopqrstuv","title":"Ignore changed metadata","view_count":"201"}]','[]');
do $$ begin
 begin perform public.sync_youtube_apply('10000000-0000-0000-0000-000000000001',null,'UCabcdefghijklmnopqrstuv','[]','[]'); raise exception 'Null lease accepted'; exception when raise_exception then if sqlerrm='Null lease accepted' then raise; end if; end;
end $$;
reset role;
do $$ begin
 if (select count(*) from public.videos where youtube_id='newvideo002')<>1 then raise exception 'Duplicate import'; end if;
 if (select count(*) from private.notification_outbox o join public.videos v on v.id=o.item_id where v.youtube_id='newvideo002')<>1 then raise exception 'Duplicate alert'; end if;
 if not exists(select 1 from public.videos where youtube_id='newvideo002' and view_count=201) then raise exception 'Metrics did not refresh'; end if;
end $$;
select 'PASS: YouTube owner-only settings, service-only sync, overlap lock, silent published backfill, future auto-publish once, manual metadata/drafts preserved, metrics, playlist RLS and lease checks' as result;
-- Manual membership and source metadata must survive unrelated sync snapshots.
insert into public.playlists(id,channel_id,youtube_playlist_id,title,sync_managed) values
 ('77777777-7777-7777-7777-777777777777','10000000-0000-0000-0000-000000000001','PLMANUAL0001','Owner title',false);
insert into public.playlist_videos(playlist_id,video_id,position) values ('77777777-7777-7777-7777-777777777777','11111111-1111-1111-1111-111111111111',0);
insert into public.channels(id,name,handle) values ('88888888-8888-8888-8888-888888888888','Other channel','@other');
insert into public.playlists(id,channel_id,youtube_playlist_id,title) values ('66666666-6666-6666-6666-666666666666','88888888-8888-8888-8888-888888888888','PLOTHER00001','Other');
do $$ begin
 begin
  insert into public.playlist_videos(playlist_id,video_id,position) values ('66666666-6666-6666-6666-666666666666','11111111-1111-1111-1111-111111111111',0);
  raise exception 'Cross-channel membership accepted';
 exception when raise_exception then if sqlerrm <> 'Playlist and video must belong to the same channel' then raise; end if; end;
end $$;
set role service_role;
select public.sync_youtube_claim('10000000-0000-0000-0000-000000000001','dddddddd-dddd-dddd-dddd-dddddddddddd');
select public.sync_youtube_apply('10000000-0000-0000-0000-000000000001','dddddddd-dddd-dddd-dddd-dddddddddddd','UCabcdefghijklmnopqrstuv','[]','[{"id":"PLMANUAL0001","title":"Source title","video_ids":[]}]');
select public.sync_youtube_claim('10000000-0000-0000-0000-000000000001','eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee');
do $$ begin
 begin
  perform public.sync_youtube_apply('10000000-0000-0000-0000-000000000001','eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee','UCabcdefghijklmnopqrstuv','[{"id":"newvideo003","channel_id":"UCabcdefghijklmnopqrstuv","title":"Must roll back"},{"id":"newvideo004","channel_id":"FOREIGN","title":"Invalid"}]','[]');
  raise exception 'Malformed snapshot accepted';
 exception when raise_exception then if sqlerrm <> 'Invalid video channel or ID' then raise; end if; end;
end $$;
reset role;
do $$ begin
 if not exists(select 1 from public.playlists where id='77777777-7777-7777-7777-777777777777' and title='Owner title') then raise exception 'Manual playlist title changed'; end if;
 if not exists(select 1 from public.playlist_videos where playlist_id='77777777-7777-7777-7777-777777777777') then raise exception 'Manual playlist membership deleted'; end if;
 if exists(select 1 from public.videos where youtube_id='newvideo003') then raise exception 'Partial snapshot persisted'; end if;
end $$;
-- Changing settings invalidates an in-flight job; it cannot commit stale policy.
set role authenticated;
set request.jwt.claim.sub='cccccccc-cccc-cccc-cccc-cccccccccccc';
select public.owner_save_youtube_settings('10000000-0000-0000-0000-000000000001','UCabcdefghijklmnopqrstuv','20000000-0000-0000-0000-000000000001',true,false);
reset role;
set role service_role;
do $$ begin
 begin
  perform public.sync_youtube_apply('10000000-0000-0000-0000-000000000001','eeeeeeee-eeee-eeee-eeee-eeeeeeeeeeee','UCabcdefghijklmnopqrstuv','[]','[]');
  raise exception 'Invalidated lease accepted';
 exception when raise_exception then if sqlerrm <> 'Sync lease expired or settings changed' then raise; end if; end;
end $$;
reset role;
select 'PASS: YouTube manual playlist preservation, cross-channel denial, atomic rollback and settings invalidation' as result;

do $$ begin
 if not exists(select 1 from public.videos where youtube_id='manual00001' and title='Owner draft' and status='draft') then raise exception 'Sync changed manual draft'; end if;
 if exists((select id,status,title from public.quizzes except select id,status,title from quizzes_before_sync) union all (select id,status,title from quizzes_before_sync except select id,status,title from public.quizzes)) then raise exception 'Sync changed quizzes'; end if;
end $$;
select 'PASS: public initial imports, silent backfill, manual drafts and owner-unpublished videos preserved; quizzes unchanged' as result;
-- Single-form quiz creation is atomic, owner-only, and always a draft.
set role anon;
set request.jwt.claim.sub='';
do $$ begin
 begin perform public.owner_create_quiz('11111111-1111-1111-1111-111111111111','Denied','{}'); raise exception 'Guest created quiz'; exception when insufficient_privilege then null; end;
end $$;
reset role;
set role authenticated;
set request.jwt.claim.sub='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
do $$ begin
 begin perform public.owner_create_quiz('11111111-1111-1111-1111-111111111111','Denied','{}'); raise exception 'Viewer created quiz'; exception when insufficient_privilege then null; end;
end $$;
set request.jwt.claim.sub='cccccccc-cccc-cccc-cccc-cccccccccccc';
do $$ declare new_quiz uuid; original_count int; question_rows jsonb; begin
 select count(*) into original_count from public.quizzes;
 begin
  perform public.owner_create_quiz('11111111-1111-1111-1111-111111111111','Bad options','{"options":["A"," "],"correct_index":0}');
  raise exception 'Blank option accepted';
 exception when raise_exception then if sqlerrm='Blank option accepted' then raise; end if; end;
 begin
  perform public.owner_create_quiz('11111111-1111-1111-1111-111111111111','Too many','{"options":["A","B","C","D","E"],"correct_index":0}');
  raise exception 'Five options accepted';
 exception when raise_exception then if sqlerrm='Five options accepted' then raise; end if; end;
 begin
  perform public.owner_create_quiz('11111111-1111-1111-1111-111111111111','Bad answer','{"options":["A","B"],"correct_index":3}');
  raise exception 'Invalid correct option accepted';
 exception when raise_exception then if sqlerrm='Invalid correct option accepted' then raise; end if; end;
 if (select count(*) from public.quizzes)<>original_count then raise exception 'Invalid quiz left an orphan'; end if;
 new_quiz:=public.owner_create_quiz('11111111-1111-1111-1111-111111111111','  New atomic quiz  ','{"prompt":" ","options":[" A "," B "],"correct_index":1,"explanation":" Because B "}');
 if not exists(select 1 from public.quizzes where id=new_quiz and status='draft' and title='New atomic quiz') then raise exception 'New quiz not draft'; end if;
 question_rows:=public.owner_quiz_questions(new_quiz);
 if jsonb_array_length(question_rows)<>1 or question_rows->0->>'prompt'<>'New atomic quiz' or question_rows->0->'options'<>'["A","B"]'::jsonb or question_rows->0->>'correct_index'<>'1' or question_rows->0->>'explanation'<>'Because B' then raise exception 'Atomic question/key incorrect'; end if;
end $$;
reset role;
set role authenticated;
set request.jwt.claim.sub='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
do $$ begin
 if exists(select 1 from public.quizzes where title='New atomic quiz') then raise exception 'Viewer saw draft quiz'; end if;
 begin perform correct_index from private.answer_keys; raise exception 'Viewer read private answers'; exception when insufficient_privilege then null; end;
end $$;
reset role;
select 'PASS: atomic owner quiz creation, private answer, title prompt fallback, draft-only state and invalid-input rollback' as result;
