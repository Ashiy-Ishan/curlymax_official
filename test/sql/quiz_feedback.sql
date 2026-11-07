-- Isolated database fixture. Never run this file in the hosted project.
insert into auth.users(id) values ('aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'),('bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'),('cccccccc-cccc-cccc-cccc-cccccccccccc');
insert into private.owners values ('cccccccc-cccc-cccc-cccc-cccccccccccc');
insert into public.videos(id,channel_id,section_id,title,youtube_url,status) values
('11111111-1111-1111-1111-111111111111','10000000-0000-0000-0000-000000000001','20000000-0000-0000-0000-000000000001','Quiz fixture','https://youtu.be/fq4N0hgOWzU','published');
insert into public.quizzes(id,video_id,title) values ('22222222-2222-2222-2222-222222222222','11111111-1111-1111-1111-111111111111','Quiz');
insert into public.questions(id,quiz_id,prompt,options,position)
select ('00000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,'22222222-2222-2222-2222-222222222222','Question '||i,'["A","B"]',i from generate_series(1,7) i;
insert into private.answer_keys(question_id,correct_index,explanation) select id,0,'Because A is correct.' from public.questions;
update public.quizzes set status='published' where id='22222222-2222-2222-2222-222222222222';
set role anon;
do $$ begin
 begin perform public.start_quiz_run('22222222-2222-2222-2222-222222222222'); raise exception 'Guest started a run'; exception when insufficient_privilege then null; end;
 begin perform public.answer_quiz_question(gen_random_uuid(),gen_random_uuid(),0); raise exception 'Guest graded a question'; exception when insufficient_privilege then null; end;
end $$;
reset role;
set role authenticated;
set request.jwt.claim.sub='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
do $$ declare started jsonb; run uuid; r jsonb; duplicate jsonb; i int; expected int; begin
 begin perform correct_index from private.answer_keys; raise exception 'Keys exposed'; exception when insufficient_privilege then null; end;
 begin perform public.owner_quiz_questions('22222222-2222-2222-2222-222222222222'); raise exception 'Viewer read owner keys'; exception when insufficient_privilege then null; end;
 started:=public.start_quiz_run('22222222-2222-2222-2222-222222222222'); run:=(started->>'run_id')::uuid;
 if started::text like '%correct_index%' or started::text like '%Because%' then raise exception 'Answer exposed before submission'; end if;
 perform set_config('request.jwt.claim.sub','bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb',false);
 begin perform public.answer_quiz_question(run,'00000000-0000-0000-0000-000000000001',0); raise exception 'Other user accessed run'; exception when insufficient_privilege then null; end;
 perform set_config('request.jwt.claim.sub','aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa',false);
 begin perform public.answer_quiz_question(run,'00000000-0000-0000-0000-000000000002',0); raise exception 'Allowed out-of-order question'; exception when raise_exception then if sqlerrm='Allowed out-of-order question' then raise; end if; end;
 begin perform public.answer_quiz_question(run,'00000000-0000-0000-0000-000000000001',4); raise exception 'Allowed invalid choice'; exception when raise_exception then if sqlerrm='Allowed invalid choice' then raise; end if; end;
 for i in 1..7 loop
  r:=public.answer_quiz_question(run,('00000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,case when i=7 then 1 else 0 end);
  expected:=least(i,6)*100+(least(i,6)/3)*50;
  if (r->>'points')::int<>expected then raise exception 'Wrong points at %: %',i,r; end if;
  if (r->>'bonus')::int<>(case when i in (3,6) then 50 else 0 end) then raise exception 'Wrong milestone'; end if;
  duplicate:=public.answer_quiz_question(run,('00000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,1);
  if r<>duplicate then raise exception 'Replay changed receipt'; end if;
 end loop;
 if (r->>'streak')::int<>0 or (r->>'correct')::boolean or not (r->>'complete')::boolean then raise exception 'Wrong completion/wrong-answer feedback'; end if;
 if (select count(*) from public.attempts)<>1 then raise exception 'Duplicate attempt'; end if;
 if not exists(select 1 from public.attempts where score=6 and total=7 and points=700) then raise exception 'Attempt not saved'; end if;
 -- Wrong answers reset streak; the next group of three earns one new bonus.
 started:=public.start_quiz_run('22222222-2222-2222-2222-222222222222'); run:=(started->>'run_id')::uuid;
 for i in 1..7 loop
  r:=public.answer_quiz_question(run,('00000000-0000-0000-0000-'||lpad(i::text,12,'0'))::uuid,case when i in (3,7) then 1 else 0 end);
  if (r->>'bonus')::int<>(case when i=6 then 50 else 0 end) then raise exception 'Streak reset failed'; end if;
 end loop;
 if (r->>'points')::int<>550 then raise exception 'Wrong reset total'; end if;

end $$;
set request.jwt.claim.sub='bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';
do $$ begin if exists(select 1 from public.attempts) then raise exception 'Other user read attempt'; end if; end $$;
set request.jwt.claim.sub='cccccccc-cccc-cccc-cccc-cccccccccccc';
do $$ declare items jsonb; begin
 items:=public.owner_quiz_questions('22222222-2222-2222-2222-222222222222');
 if items->0->>'explanation'<>'Because A is correct.' then raise exception 'Owner explanation missing'; end if;
end $$;
reset role;
select 'PASS: guest/user isolation, private keys, order/choice validation, 3/6 streak milestones, reset, replay safety, single saved attempt, owner explanations' as result;
