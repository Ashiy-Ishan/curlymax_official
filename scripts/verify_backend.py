#!/usr/bin/env python3
"""Local-only destructive test fixtures. No secrets are printed. Uses real REST/Auth, not UI checks."""
import json, secrets, subprocess, urllib.request, urllib.error, uuid
from urllib.parse import urlencode

config = json.loads(subprocess.check_output(['supabase','status','-o','json'],stderr=subprocess.DEVNULL))
base=config['API_URL']
if base != 'http://127.0.0.1:55321':
    raise SystemExit('Run only against the CURLYmax local stack on port 55321.')
anon=config['ANON_KEY']; service=config['SERVICE_ROLE_KEY']

def api(path, token=anon, method='GET', body=None, schema=None):
    headers={'apikey':anon,'Authorization':'Bearer '+token,'Content-Type':'application/json','Prefer':'return=representation'}
    if schema: headers.update({'Accept-Profile':schema,'Content-Profile':schema})
    req=urllib.request.Request(base+path,headers=headers,method=method,data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(req,timeout=20) as response:
            raw=response.read(); return response.status,json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw=e.read().decode()
        try: return e.code,json.loads(raw)
        except json.JSONDecodeError: return e.code,raw

def sql(statement):
    return subprocess.check_output(['docker','exec','-i','supabase_db_curlymax','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-At'],input=statement.encode()).decode().strip()

def check(name,condition):
    assert condition,name
    print('PASS '+name)

ids=[str(uuid.uuid4()) for _ in range(10)]
video,draft,quiz,question,channel,section=ids[:6]
users=[]
try:
    for suffix in ['a','b']:
        email=f'rls-{uuid.uuid4().hex}-{suffix}@example.test'; password=secrets.token_urlsafe(24)
        status,user=api('/auth/v1/admin/users',service,'POST',{'email':email,'password':password,'email_confirm':True})
        assert status==200,(status,'Create test user')
        users.append(user['id'])
        status,session=api('/auth/v1/token?grant_type=password',anon,'POST',{'email':email,'password':password})
        assert status==200
        if suffix=='a': a=session['access_token']
        else: b=session['access_token']
    sql(f"""
    insert into public.channels(id,name,handle) values('{channel}','RLS fixture','@fixture-{channel}');
    insert into public.sections(id,channel_id,name) values('{section}','{channel}','Test');
    insert into public.videos(id,channel_id,section_id,title,youtube_url,status) values
    ('{video}','{channel}','{section}','Published fixture','https://youtu.be/fq4N0hgOWzU','published'),
    ('{draft}','{channel}','{section}','Draft fixture','https://www.youtube.com/shorts/fq4N0hgOWzU','draft');
    insert into public.quizzes(id,video_id,title) values('{quiz}','{video}','Test quiz');
    insert into public.questions(id,quiz_id,prompt,options,position) values('{question}','{quiz}','Pick first','["First","Second"]',0);
    insert into private.answer_keys values('{question}',0);
    update public.quizzes set status='published' where id='{quiz}';
    """)
    check('watch / short / short-link parsing',sql("select public.youtube_id('https://www.youtube.com/watch?list=x&v=fq4N0hgOWzU&t=3')=public.youtube_id('https://youtu.be/fq4N0hgOWzU?si=x') and public.youtube_id('https://youtube.com/shorts/fq4N0hgOWzU')='fq4N0hgOWzU';")=='t')
    status,data=api(f'/rest/v1/videos?id=eq.{video}')
    check('guest reads published video',status==200 and len(data)==1)
    for token,name in [(anon,'guest'),(a,'user A'),(b,'user B')]:
        status,data=api(f'/rest/v1/videos?id=eq.{draft}',token)
        check(name+' cannot read drafts',status==200 and data==[])
        status,data=api('/rest/v1/channels',token,'POST',{'name':'Unauthorized','handle':'@denied'})
        check(name+' cannot publish',status>=400)
        status,data=api('/rest/v1/answer_keys',token,schema='private')
        check(name+' cannot read answer keys',status>=400)
        status,data=api('/rest/v1/rpc/claim_notifications',token,'POST',{})
        check(name+' cannot claim notifications',status>=400)
    status,data=api(f'/rest/v1/questions?quiz_id=eq.{quiz}')
    check('guest cannot read quiz questions',status>=400)
    status,data=api('/rest/v1/rpc/submit_quiz',anon,'POST',{'quiz':quiz,'answers':{question:0}})
    check('guest cannot submit quiz',status>=400)
    status,data=api(f'/rest/v1/questions?quiz_id=eq.{quiz}',a)
    check('signed-in user sees questions without key',status==200 and len(data)==1 and 'correct_index' not in data[0])
    status,data=api('/rest/v1/notes',a,'POST',{'video_id':video,'body':'Private A'})
    check('A creates own note',status==201 and data[0]['user_id']==users[0]); note=data[0]['id']
    for token,name in [(anon,'guest'),(b,'B')]:
        status,data=api(f'/rest/v1/notes?id=eq.{note}',token)
        check(name+' cannot read A note',(status>=400) or data==[])
        status,data=api(f'/rest/v1/notes?id=eq.{note}',token,'PATCH',{'body':'stolen'})
        check(name+' cannot edit A note',(status>=400) or data==[])
        status,data=api(f'/rest/v1/notes?id=eq.{note}',token,'DELETE')
        check(name+' cannot delete A note',(status>=400) or data==[])
    status,data=api('/rest/v1/notes',b,'POST',{'user_id':users[0],'video_id':video,'body':'spoof'})
    check('B cannot spoof note owner',status>=400)
    status,data=api(f'/rest/v1/notes?id=eq.{note}',a,'PATCH',{'body':'Updated A'})
    check('A edits own note',status==200 and data[0]['body']=='Updated A')
    status,data=api('/rest/v1/rpc/submit_quiz',a,'POST',{'quiz':quiz,'answers':{question:0}})
    check('server grades correct submission',status==200 and data['score']==1 and data['user_id']==users[0]); attempt=data['id']
    status,data=api('/rest/v1/rpc/submit_quiz',a,'POST',{'quiz':quiz,'answers':{question:1}})
    check('server grades retry independently',status==200 and data['score']==0)
    status,data=api('/rest/v1/rpc/submit_quiz',a,'POST',{'quiz':quiz,'answers':{}})
    check('incomplete submission rejected',status>=400)
    status,data=api('/rest/v1/attempts',a,'POST',{'quiz_id':quiz,'user_id':users[0],'score':99,'total':1})
    check('client cannot forge score',status>=400)
    status,data=api(f'/rest/v1/attempts?id=eq.{attempt}',b)
    check('B cannot read A attempt',status==200 and data==[])
    status,data=api(f'/rest/v1/attempts?id=eq.{attempt}',a)
    check('A can read own attempt',status==200 and len(data)==1)
    status,data=api('/rest/v1/rpc/submit_quiz',b,'POST',{'quiz':quiz,'answers':{question:1}})
    check('B creates isolated attempt',status==200 and data['user_id']==users[1])
    status,data=api('/rest/v1/notes',b,'POST',{'video_id':video,'body':'Private B'})
    other=data[0]['id']; status,data=api(f'/rest/v1/notes?id=eq.{other}',a)
    check('A cannot read B note',status==200 and data==[])
    status,data=api(f'/rest/v1/notes?id=eq.{note}',a,'DELETE')
    check('A deletes own note',status==200 and len(data)==1)
    sql(f"update public.videos set status='draft' where id='{video}'; update public.videos set status='published' where id='{video}';")
    check('republishing does not duplicate notification',sql(f"select count(*) from private.notification_outbox where item_id='{video}';")=='1')
    sql(f"update public.channels set active=false where id='{channel}';")
    status,data=api(f'/rest/v1/videos?id=eq.{video}')
    check('inactive channel hides video',status==200 and data==[])
    status,data=api('/rest/v1/rpc/submit_quiz',a,'POST',{'quiz':quiz,'answers':{question:0}})
    check('hidden parent prevents grading',status>=400)
    status,data=api('/rest/v1/rpc/submit_quiz',a,'POST',{'quiz':quiz,'answers':None})
    check('null answers rejected',status>=400)
    sql(f"update public.channels set active=true where id='{channel}'; insert into private.owners values('{users[0]}'); update public.quizzes set status='draft' where id='{quiz}';")
    status,data=api(f'/rest/v1/channels?id=eq.{channel}',a,'PATCH',{'name':'Owner edit'})
    check('database-appointed owner can edit catalog',status==200 and len(data)==1)
    status,data=api(f'/rest/v1/questions?id=eq.{question}',a,'PATCH',{'options':['Correct','Other']})
    check('owner can edit draft questions through API',status==200 and len(data)==1)
    status,data=api('/rest/v1/rpc/set_answer_key',b,'POST',{'question':question,'answer_index':0})
    check('viewer cannot set answer key',status>=400)
    status,data=api('/rest/v1/rpc/set_answer_key',a,'POST',{'question':question,'answer_index':0})
    check('owner can set private draft answer key',status<300)
    status,data=api(f'/rest/v1/quizzes?id=eq.{quiz}',a,'PATCH',{'status':'published'})
    check('owner can publish complete quiz',status==200 and len(data)==1)
    status,data=api(f'/rest/v1/questions?id=eq.{question}',a,'PATCH',{'prompt':'Changed after publish'})
    check('published questions are frozen',status>=400)
    status,data=api('/functions/v1/notify-published',anon,'POST',{})
    check('worker rejects caller without scheduler secret',status==401)
    from concurrent.futures import ThreadPoolExecutor
    with ThreadPoolExecutor(max_workers=2) as workers:
        claims=list(workers.map(lambda _: api('/rest/v1/rpc/claim_notifications',service,'POST',{}),range(2)))
    events=[e for status,batch in claims for e in (batch if status==200 else []) if e['item_id'] in [video,quiz]]
    check('concurrent workers claim publication events once',len(events)==2 and len(set(e['id'] for e in events))==2)
    for event in events:
        status,data=api('/rest/v1/rpc/finish_notification',service,'POST',{'event':event['id'],'succeeded':True,'message':'Local transport-free test'})
        check('service worker can finish claimed event',status<300)
    status,data=api('/rest/v1/rpc/claim_notifications',service,'POST',{})
    check('sent events are not claimed again',status==200 and not any(e['item_id'] in [video,quiz] for e in data))
    print('All direct backend permission checks passed.')
finally:
    # Only remove fixtures created by this run; leave unrelated local data intact.
    sql(f"""delete from public.notes where video_id in ('{video}','{draft}'); delete from public.attempts where quiz_id='{quiz}';
    update public.quizzes set status='draft' where id='{quiz}'; delete from public.quizzes where id='{quiz}';
    delete from public.videos where id in ('{video}','{draft}'); delete from public.sections where id='{section}'; delete from public.channels where id='{channel}';
    delete from private.notification_outbox where item_id in ('{video}','{draft}','{quiz}');""")
    for user in users: sql(f"delete from private.owners where user_id='{user}';")
    for user in users: api('/auth/v1/admin/users/'+user,service,'DELETE')
