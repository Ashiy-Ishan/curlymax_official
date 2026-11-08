-- Destructive fixture checks: run last, only inside the disposable database.
set role anon;
set request.jwt.claim.sub='';
do $$ begin
 begin delete from auth.users where id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; raise exception 'Guest deleted Auth user'; exception when insufficient_privilege then null; end;
end $$;
reset role;
set role authenticated;
set request.jwt.claim.sub='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
do $$ begin
 begin delete from auth.users where id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; raise exception 'Viewer directly deleted Auth user'; exception when insufficient_privilege then null; end;
 begin delete from private.owners; raise exception 'Viewer removed owner membership'; exception when insufficient_privilege then null; end;
end $$;
reset role;
-- Both accounts own private data. Auth Admin deletes only authenticated caller A.
insert into public.notes(user_id,video_id,body) values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','11111111-1111-1111-1111-111111111111','B survives');
insert into public.attempts(user_id,quiz_id,score,total,points) values ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','22222222-2222-2222-2222-222222222222',0,1,0);
create temporary table catalog_before as select (select count(*) from public.videos) videos,(select count(*) from public.quizzes) quizzes,(select count(*) from public.channels) channels;
-- Seed unfinished runs after previous quiz-edit invalidation.
insert into private.quiz_runs(user_id,quiz_id,question_ids) values
 ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa','22222222-2222-2222-2222-222222222222',array[]::uuid[]),
 ('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb','22222222-2222-2222-2222-222222222222',array[]::uuid[]);
delete from auth.users where id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
do $$ begin
 if exists(select 1 from public.notes where user_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') or
    exists(select 1 from public.attempts where user_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') or
    exists(select 1 from private.quiz_runs where user_id='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa') then raise exception 'Deleted user retained private rows'; end if;
 if not exists(select 1 from auth.users where id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') or
    not exists(select 1 from public.notes where user_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') or
    not exists(select 1 from public.attempts where user_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') or
    not exists(select 1 from private.quiz_runs where user_id='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb') then raise exception 'Deletion affected another user'; end if;
end $$;
-- Owner may delete their own account too; catalog belongs to the application.
delete from auth.users where id='cccccccc-cccc-cccc-cccc-cccccccccccc';
do $$ begin
 if exists(select 1 from private.owners) then raise exception 'Deleted owner membership survived'; end if;
 if exists(select 1 from catalog_before b where b.videos<>(select count(*) from public.videos) or b.quizzes<>(select count(*) from public.quizzes) or b.channels<>(select count(*) from public.channels)) then raise exception 'Account deletion changed catalog'; end if;
end $$;
select 'PASS: direct Auth deletion denied, account private-data cascade isolated, owner deletion supported, shared catalog retained' as result;
