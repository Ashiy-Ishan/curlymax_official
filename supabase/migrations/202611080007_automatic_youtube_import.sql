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
