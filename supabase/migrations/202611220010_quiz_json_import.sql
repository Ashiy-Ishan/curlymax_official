-- Import a complete quiz atomically; never publish imported content automatically.
begin;
create or replace function public.owner_import_quiz(video_id uuid, title text, items jsonb)
returns uuid language plpgsql security definer set search_path='' as $$
declare quiz_id uuid; item jsonb; choices jsonb; clean_title text:=trim(title);
begin
 if not public.is_owner() then raise exception 'Owner only' using errcode='42501'; end if;
 if clean_title is null or length(clean_title) not between 1 and 500 then raise exception 'Quiz title must contain 1 to 500 characters'; end if;
 if items is null or octet_length(items::text)>1048576 then raise exception 'Quiz JSON is too large'; end if;
 if jsonb_typeof(items) is distinct from 'array' then raise exception 'Questions must be an array'; end if;
 if jsonb_array_length(items) not between 1 and 100 then raise exception 'Provide 1 to 100 questions'; end if;
 perform 1 from public.videos v where v.id=video_id;
 if not found then raise exception 'Video not found'; end if;
 for item in select value from jsonb_array_elements(items) loop
  if jsonb_typeof(item) is distinct from 'object' then raise exception 'Each question must be an object'; end if;
  if exists(select 1 from jsonb_object_keys(item) k where k not in ('prompt','options','correct_index','explanation')) then raise exception 'Unsupported question field'; end if;
  if jsonb_typeof(item->'prompt') is distinct from 'string' or length(trim(item->>'prompt')) not between 1 and 5000 then raise exception 'Question prompt must contain 1 to 5000 characters'; end if;
  choices:=item->'options';
  if jsonb_typeof(choices) is distinct from 'array' then raise exception 'Options must be an array'; end if;
  if jsonb_array_length(choices) not between 2 and 4 then raise exception 'Provide 2 to 4 options'; end if;
  if exists(select 1 from jsonb_array_elements(choices) o where jsonb_typeof(o)<>'string' or length(trim(o #>> '{}')) not between 1 and 1000) then raise exception 'Options must contain 1 to 1000 characters'; end if;
  if jsonb_typeof(item->'correct_index') is distinct from 'number' or coalesce(item->>'correct_index','') !~ '^[0-3]$' then raise exception 'Provide a zero-based integer answer index'; end if;
  if (item->>'correct_index')::int>=jsonb_array_length(choices) then raise exception 'Answer index outside options'; end if;
  if item ? 'explanation' and (jsonb_typeof(item->'explanation') is distinct from 'string' or length(item->>'explanation')>5000) then raise exception 'Explanation must be text up to 5000 characters'; end if;
 end loop;
 insert into public.quizzes(video_id,title,status) values(video_id,clean_title,'draft') returning id into quiz_id;
 perform public.owner_save_questions(quiz_id,items);
 return quiz_id;
end $$;
revoke all on function public.owner_import_quiz(uuid,text,jsonb) from public,anon;
grant execute on function public.owner_import_quiz(uuid,text,jsonb) to authenticated;
notify pgrst,'reload schema';
commit;
