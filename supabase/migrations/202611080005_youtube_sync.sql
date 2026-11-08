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
 last_synced_at timestamptz, last_error text,
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
 select s.channel_id from private.youtube_sync_settings s join public.channels c on c.id=s.channel_id where s.enabled and c.active order by s.last_synced_at nulls first,s.channel_id
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
 update private.youtube_sync_settings set lease=token,lease_until=now()+interval '10 minutes' where channel_id=target;
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
