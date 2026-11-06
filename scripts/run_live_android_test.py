#!/usr/bin/env python3
"""Test real Supabase Auth/RLS on Android using isolated LOCAL fixtures, then remove them."""
import json,secrets,subprocess,tempfile,urllib.request,urllib.error,uuid,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
config=json.loads(subprocess.check_output(['supabase','status','-o','json'],cwd=root,stderr=subprocess.DEVNULL))
base=config['API_URL']
if base!='http://127.0.0.1:55321':sys.exit('Run only against the local CURLYmax stack on port 55321. Use supabase start first.')
service=config['SERVICE_ROLE_KEY'];anon=config['ANON_KEY']
ids=[str(uuid.uuid4()) for _ in range(6)]
channel,section,video,quiz,q1,q2=ids
user=None;settings_path=None
email=f'android-{uuid.uuid4().hex}@example.test';password=secrets.token_urlsafe(24)

def api(path,method='GET',body=None):
    req=urllib.request.Request(base+path,method=method,headers={'apikey':anon,'Authorization':'Bearer '+service,'Content-Type':'application/json'},data=None if body is None else json.dumps(body).encode())
    with urllib.request.urlopen(req,timeout=20) as response:
        raw=response.read();return json.loads(raw) if raw else None

def sql(statement):
    subprocess.run(['docker','exec','-i','supabase_db_curlymax','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1'],input=statement.encode(),check=True,stdout=subprocess.DEVNULL)

try:
    user=api('/auth/v1/admin/users','POST',{'email':email,'password':password,'email_confirm':True})['id']
    sql(f"""
    insert into public.channels(id,name,handle) values('{channel}','Android test channel','@android-{channel}');
    insert into public.sections(id,channel_id,name) values('{section}','{channel}','Integration tests');
    insert into public.videos(id,channel_id,section_id,title,youtube_url,status) values('{video}','{channel}','{section}','Integration fixture','https://youtu.be/fq4N0hgOWzU','published');
    insert into public.quizzes(id,video_id,title) values('{quiz}','{video}','Server-scored integration quiz');
    insert into public.questions(id,quiz_id,prompt,options,position) values
    ('{q1}','{quiz}','Question one','["First correct option","First other option"]',0),
    ('{q2}','{quiz}','Question two','["Second correct option","Second other option"]',1);
    insert into private.answer_keys(question_id,correct_index) values('{q1}',0),('{q2}',0);
    update public.quizzes set status='published' where id='{quiz}';
    """)
    with tempfile.TemporaryDirectory(prefix='curlymax-android-') as temp:
        settings_path=Path(temp)/'integration.json'
        settings_path.write_text(json.dumps({'SUPABASE_URL':'http://10.0.2.2:55321','SUPABASE_ANON_KEY':anon,'FCM_ENABLED':False,'TEST_EMAIL':email,'TEST_PASSWORD':password,'TEST_VIDEO_ID':video,'TEST_QUIZ_ID':quiz}))
        subprocess.run(['flutter','build','apk','--debug','--target=integration_test/live_test.dart','--target-platform=android-arm64',f'--dart-define-from-file={settings_path}'],cwd=root,check=True)
        # Avoid building while the emulator runs on memory-limited machines.
        subprocess.run(['./gradlew','--stop'],cwd=root/'android',check=True)
        test_apk=Path(temp)/'integration.apk'
        import shutil
        shutil.copy2(root/'build/app/outputs/flutter-apk/app-debug.apk',test_apk)
        subprocess.run(['flutter','drive','--no-pub','--driver=test_driver/integration_test.dart','--target=integration_test/live_test.dart',f'--use-application-binary={test_apk}','-d',sys.argv[1] if len(sys.argv)>1 else 'emulator-5554'],cwd=root,check=True)
finally:
    sql(f"""delete from public.notes where video_id='{video}'; delete from public.attempts where quiz_id='{quiz}';
    update public.quizzes set status='draft' where id='{quiz}'; delete from public.quizzes where id='{quiz}';
    delete from public.videos where id='{video}'; delete from public.sections where id='{section}'; delete from public.channels where id='{channel}';
    delete from private.notification_outbox where item_id in ('{video}','{quiz}');""")
    if user:api('/auth/v1/admin/users/'+user,'DELETE')
