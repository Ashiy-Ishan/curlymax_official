#!/usr/bin/env python3
"""Run migrations and role-based scoring checks in a disposable offline Postgres container."""
from pathlib import Path
import subprocess
import json
from concurrent.futures import ThreadPoolExecutor
import time
import uuid
root = Path(__file__).resolve().parents[1]
name = 'curlymax-quiz-test-' + uuid.uuid4().hex[:8]
def sql(text):
    return subprocess.check_output(['docker','exec','-i',name,'psql','-U','postgres','-v','ON_ERROR_STOP=1','-At'],input=text.encode()).decode()
try:
    subprocess.run(['docker','run','--pull=never','-d','--name',name,'--network','none','-e','POSTGRES_HOST_AUTH_METHOD=trust','postgres:15-alpine'],check=True,stdout=subprocess.DEVNULL)
    for _ in range(30):
        ready = subprocess.run(['docker','exec',name,'pg_isready','-U','postgres'],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
        if ready.returncode == 0: break
        time.sleep(1)
    else: raise RuntimeError('Test database not ready')
    sql("""create role anon; create role authenticated; create role service_role;
    create schema auth; create table auth.users(id uuid primary key);
    create function auth.uid() returns uuid language sql stable as $$ select nullif(current_setting('request.jwt.claim.sub',true),'')::uuid $$;
    create publication supabase_realtime;""")
    for path in sorted((root/'supabase/migrations').glob('*.sql')):
        sql(path.read_text())
    print(sql((root/'test/sql/quiz_feedback.sql').read_text()).splitlines()[-1])
    print(sql((root/'test/sql/youtube_sync.sql').read_text()).splitlines()[-1])
    viewer = "set role authenticated; set request.jwt.claim.sub='aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'; "
    run = json.loads(sql(viewer + "select public.start_quiz_run('22222222-2222-2222-2222-222222222222');").splitlines()[-1])['run_id']
    def concurrent_answer(_):
        return json.loads(sql(viewer + f"select public.answer_quiz_question('{run}','00000000-0000-0000-0000-000000000001',0);").splitlines()[-1])
    with ThreadPoolExecutor(max_workers=2) as pool:
        receipts = list(pool.map(concurrent_answer, range(2)))
    assert receipts[0] == receipts[1] and receipts[0]['points'] == 100
    print('PASS: concurrent duplicate submissions award only once')
    sql("update public.quizzes set status='draft' where id='22222222-2222-2222-2222-222222222222';")
    sql("""set role authenticated; set request.jwt.claim.sub='cccccccc-cccc-cccc-cccc-cccccccccccc';
    do $$ begin
      begin
        perform public.owner_save_questions('22222222-2222-2222-2222-222222222222','[{"prompt":"Invalid","options":["A","B"],"correct_index":5}]');
        raise exception 'Invalid editor save accepted';
      exception when raise_exception then if sqlerrm='Invalid editor save accepted' then raise; end if; end;
      if (select count(*) from public.questions where quiz_id='22222222-2222-2222-2222-222222222222')<>7 then raise exception 'Failed edit lost questions'; end if;
      perform public.owner_save_questions('22222222-2222-2222-2222-222222222222','[{"prompt":"Updated","options":["A","B"],"correct_index":0,"explanation":"Private owner explanation"}]');
      if public.owner_quiz_questions('22222222-2222-2222-2222-222222222222')->0->>'explanation'<>'Private owner explanation' then raise exception 'Explanation not saved'; end if;
    end $$;""")
    sql(viewer + f"""do $$ begin
      begin perform public.answer_quiz_question('{run}','00000000-0000-0000-0000-000000000002',0);
      raise exception 'Stale run remained accessible'; exception when insufficient_privilege then null; end;
    end $$;""")
    print('PASS: atomic owner edits, private explanations and stale-run invalidation')


finally:
    subprocess.run(['docker','rm','-f',name],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
