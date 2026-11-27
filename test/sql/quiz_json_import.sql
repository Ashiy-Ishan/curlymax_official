begin;
set role anon;
do $$ begin
 begin perform public.owner_import_quiz('11111111-1111-1111-1111-111111111111','Denied','[]'); raise exception 'Guest imported quiz'; exception when insufficient_privilege then null; end;
end $$;
reset role;
set role authenticated;
set request.jwt.claim.sub='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa';
do $$ begin
 begin perform public.owner_import_quiz('11111111-1111-1111-1111-111111111111','Denied','[]'); raise exception 'Viewer imported quiz'; exception when insufficient_privilege then null; end;
end $$;
set request.jwt.claim.sub='cccccccc-cccc-cccc-cccc-cccccccccccc';
do $$ declare imported_id uuid; n int; result jsonb; begin
 select count(*) into n from public.quizzes;
 begin
 perform public.owner_import_quiz('11111111-1111-1111-1111-111111111111','Bad','[{"prompt":"Valid","options":["A","B"],"correct_index":0},{"prompt":"Invalid","options":["A","B"],"correct_index":2}]');
 raise exception 'Invalid import accepted';
 exception when raise_exception then if sqlerrm='Invalid import accepted' then raise; end if; end;
 if (select count(*) from public.quizzes)<>n then raise exception 'Failed import left partial quiz'; end if;
 imported_id:=public.owner_import_quiz('11111111-1111-1111-1111-111111111111','SQL-shaped text: DROP TABLE quizzes;--','[{"prompt":"First?","options":["A","B"],"correct_index":0,"explanation":"Private feedback"},{"prompt":"Second?","options":["C","D","E","F"],"correct_index":3}]');
 if (select status from public.quizzes where public.quizzes.id=imported_id)<>'draft' then raise exception 'Import published automatically'; end if;
 result:=public.owner_quiz_questions(imported_id);
 if jsonb_array_length(result)<>2 or result->0->>'explanation'<>'Private feedback' or (result->1->>'correct_index')::int<>3 then raise exception 'Imported quiz did not preserve questions'; end if;
end $$;
reset role;
rollback;
select 'PASS: owner-only atomic JSON quiz import, draft status, private answers and rollback';
