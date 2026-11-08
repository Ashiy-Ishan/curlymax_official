-- After quiz_feedback.sql fixtures, only in the isolated test database.
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
 '[{"id":"fq4N0hgOWzU","channel_id":"UCabcdefghijklmnopqrstuv","title":"Overwrite attempt","view_count":"20"},{"id":"newvideo001","channel_id":"UCabcdefghijklmnopqrstuv","title":"Initial import","view_count":"10"}]',
 '[{"id":"PL1234567890","title":"Playlist","video_ids":["fq4N0hgOWzU","newvideo001"]}]');
end $$;
reset role;
do $$ begin
 if not exists(select 1 from public.videos where youtube_id='newvideo001' and status='draft') then raise exception 'Initial import was published'; end if;
 if not exists(select 1 from public.videos where youtube_id='fq4N0hgOWzU' and title='Quiz fixture' and status='published' and view_count=20) then raise exception 'Manual metadata changed'; end if;
 if exists(select 1 from private.notification_outbox o join public.videos v on v.id=o.item_id where v.youtube_id='newvideo001') then raise exception 'Initial import alert'; end if;
end $$;
set role anon;
set request.jwt.claim.sub='';
do $$ begin
 if (select count(*) from public.playlist_videos)<>1 then raise exception 'Guest saw draft playlist video'; end if;
 if exists(select 1 from public.videos where youtube_id='newvideo001') then raise exception 'Guest saw initial draft'; end if;
end $$;
reset role;
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
select 'PASS: YouTube owner-only settings, service-only sync, overlap lock, silent draft backfill, future auto-publish once, manual metadata/drafts preserved, metrics, playlist RLS and lease checks' as result;
