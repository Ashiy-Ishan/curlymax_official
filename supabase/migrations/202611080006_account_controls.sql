-- Account deletion uses Auth Admin on the server, with caller identity verified
-- by the delete-account function. Cascades remove only that user's private rows.
begin;
alter table public.channels add column avatar_url text
 check(avatar_url is null or (length(avatar_url)<=2048 and avatar_url ~ '^https://[^[:space:]]+$'));
alter table private.owners drop constraint owners_user_id_fkey;
alter table private.owners add constraint owners_user_id_fkey
 foreign key(user_id) references auth.users(id) on delete cascade;
notify pgrst,'reload schema';
commit;
