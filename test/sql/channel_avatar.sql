-- Runs after YouTube fixtures, before account deletion tests.
update public.channels set avatar_url='https://example.com/owner-logo.png' where id='10000000-0000-0000-0000-000000000001';
set role anon;
set request.jwt.claim.sub='';
do $$ begin
 begin perform public.sync_youtube_channel_avatar('10000000-0000-0000-0000-000000000001','UCabcdefghijklmnopqrstuv','https://yt3.ggpht.com/guest'); raise exception 'Guest changed source avatar'; exception when insufficient_privilege then null; end;
end $$;
reset role;
set role authenticated;
set request.jwt.claim.sub='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
do $$ begin
 begin perform public.sync_youtube_channel_avatar('10000000-0000-0000-0000-000000000001','UCabcdefghijklmnopqrstuv','https://yt3.ggpht.com/viewer'); raise exception 'Viewer changed source avatar'; exception when insufficient_privilege then null; end;
end $$;
reset role;
set role service_role;
select public.sync_youtube_channel_avatar('10000000-0000-0000-0000-000000000001','UCabcdefghijklmnopqrstuv','https://yt3.ggpht.com/first=s800');
select public.sync_youtube_channel_avatar('10000000-0000-0000-0000-000000000001','UCabcdefghijklmnopqrstuv','https://yt3.googleusercontent.com/current=s800');
select public.sync_youtube_channel_avatar('10000000-0000-0000-0000-000000000001','UCabcdefghijklmnopqrstuv',null);
do $$ declare invalid_url text; begin
 foreach invalid_url in array array['http://yt3.ggpht.com/logo','https://yt3.ggpht.com.evil.example/logo','https://yt3.ggpht.com@evil.example/logo','https://evil.example/logo','https://yt3.ggpht.com:443/logo','https://yt3.ggpht.com/white space','https://yt3.ggpht.com/'||repeat('a',2048)] loop
  begin perform public.sync_youtube_channel_avatar('10000000-0000-0000-0000-000000000001','UCabcdefghijklmnopqrstuv',invalid_url); raise exception 'Invalid avatar URL accepted';
  exception when raise_exception then if sqlerrm <> 'Use a valid HTTPS YouTube thumbnail URL' then raise; end if; end;
 end loop;
 begin perform public.sync_youtube_channel_avatar('10000000-0000-0000-0000-000000000001','UCzzzzzzzzzzzzzzzzzzzzzz','https://yt3.ggpht.com/logo'); raise exception 'Wrong source channel accepted';
 exception when raise_exception then if sqlerrm <> 'YouTube channel mismatch or unavailable' then raise; end if; end;
end $$;
reset role;
set role anon;
set request.jwt.claim.sub='';
do $$ begin
 if not exists(select 1 from public.channels where id='10000000-0000-0000-0000-000000000001' and avatar_url='https://example.com/owner-logo.png' and youtube_avatar_url='https://yt3.googleusercontent.com/current=s800') then raise exception 'Source avatar inaccessible or manual override changed'; end if;
end $$;
reset role;
select 'PASS: service-only channel avatar, exact HTTPS hosts, channel identity validation, missing-logo preservation and manual override retained' as result;

-- Existing APKs read avatar_url: fill empty values and refresh only matching
-- previous automatic copies, never a distinct owner override.
update public.channels set avatar_url=null where id='10000000-0000-0000-0000-000000000001';
set role service_role;
select public.sync_youtube_channel_avatar('10000000-0000-0000-0000-000000000001','UCabcdefghijklmnopqrstuv','https://yt3.ggpht.com/legacy-first');
reset role;
do $$ begin
 if not exists(select 1 from public.channels where id='10000000-0000-0000-0000-000000000001' and avatar_url='https://yt3.ggpht.com/legacy-first' and youtube_avatar_url=avatar_url) then raise exception 'Legacy blank avatar not filled'; end if;
end $$;
set role service_role;
select public.sync_youtube_channel_avatar('10000000-0000-0000-0000-000000000001','UCabcdefghijklmnopqrstuv','https://yt3.ggpht.com/legacy-refreshed');
select public.sync_youtube_channel_avatar('10000000-0000-0000-0000-000000000001','UCabcdefghijklmnopqrstuv',null);
reset role;
do $$ begin
 if not exists(select 1 from public.channels where id='10000000-0000-0000-0000-000000000001' and avatar_url='https://yt3.ggpht.com/legacy-refreshed' and youtube_avatar_url=avatar_url) then raise exception 'Legacy automatic copy not refreshed or null erased it'; end if;
end $$;
select 'PASS: legacy APK blank logo filled, previous automatic logo refreshed, missing logo preserves both fields' as result;
