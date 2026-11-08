-- Keep owner override separate from the automatically refreshed YouTube logo.
begin;
alter table public.channels add column youtube_avatar_url text
 check(youtube_avatar_url is null or (length(youtube_avatar_url)<=2048 and youtube_avatar_url ~ '^https://(yt3[.]ggpht[.]com|yt3[.]googleusercontent[.]com|i[.]ytimg[.]com)/[^[:space:][:cntrl:]]*$'));
create function public.sync_youtube_channel_avatar(target uuid,resolved_channel text,logo_url text)
returns void language plpgsql security definer set search_path='' as $$
begin
 -- Lock and recheck the source identity after catalog synchronization. A stale
 -- worker must not attach another YouTube channel's logo after an owner edit.
 perform 1 from public.channels c where c.id=target and c.active
  and resolved_channel ~ '^UC[A-Za-z0-9_-]{22}$' and c.youtube_channel_id=resolved_channel for update;
 if not found then raise exception 'YouTube channel mismatch or unavailable'; end if;
 -- Missing provider thumbnail does not erase the previous valid source logo.
 if logo_url is null then return; end if;
 if length(logo_url)>2048 or logo_url !~ '^https://(yt3[.]ggpht[.]com|yt3[.]googleusercontent[.]com|i[.]ytimg[.]com)/[^[:space:][:cntrl:]]*$' then
  raise exception 'Use a valid HTTPS YouTube thumbnail URL';
 end if;
 -- Older installed clients only read avatar_url. Refresh its automatic copy
 -- when empty or still equal to the previous source; preserve manual overrides.
 update public.channels set
  avatar_url=case when nullif(trim(avatar_url),'') is null or avatar_url=youtube_avatar_url then logo_url else avatar_url end,
  youtube_avatar_url=logo_url
 where id=target;
end $$;
revoke all on function public.sync_youtube_channel_avatar(uuid,text,text) from public,anon,authenticated;
grant execute on function public.sync_youtube_channel_avatar(uuid,text,text) to service_role;
notify pgrst,'reload schema';
commit;
