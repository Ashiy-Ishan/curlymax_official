#!/usr/bin/env python3
"""Read-only checks using the app's public Supabase key. No credentials are printed."""
import json, sys, urllib.request, urllib.error
from pathlib import Path
from concurrent.futures import ThreadPoolExecutor
root=Path(__file__).resolve().parents[1]
config=json.loads((root/'config/live.json').read_text())
base=config['SUPABASE_URL'].rstrip('/')
key=config.get('SUPABASE_PUBLISHABLE_KEY') or config.get('SUPABASE_ANON_KEY')

def request(path,method='GET',body=None):
    req=urllib.request.Request(base+path,method=method,headers={'apikey':key,'Content-Type':'application/json'},
        data=None if body is None else json.dumps(body).encode())
    try:
        with urllib.request.urlopen(req,timeout=20) as r:
            raw=r.read();return r.status,json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        raw=e.read().decode()
        try:return e.code,json.loads(raw)
        except json.JSONDecodeError:return e.code,None

tables=['channels','sections','videos','quizzes','playlists','playlist_videos']
paths=[f'/rest/v1/{table}?select={"playlist_id" if table=="playlist_videos" else "id"}&limit=1' for table in tables]
with ThreadPoolExecutor(max_workers=4) as pool:results=list(pool.map(request,paths))
failed=False
for table,(status,data) in zip(tables,results):
    passed=status==200
    print(('PASS' if passed else 'FAIL')+f' guest catalog table {table}: HTTP {status}')
    failed |= not passed
schema_ready=not failed
for table in ['questions','notes','attempts']:
    if not schema_ready:
        print(f'SKIP private-table access check {table}: schema is not ready')
        continue
    status,_=request(f'/rest/v1/{table}?select=id&limit=1')
    passed=status in [401,403]
    print(('PASS' if passed else 'FAIL')+f' guest denied {table}: HTTP {status}')
    failed |= not passed
for name,body in [('submit_quiz',{'quiz':'00000000-0000-0000-0000-000000000000','answers':{}}),('claim_notifications',{}),('owner_youtube_settings',{}),('owner_youtube_analytics',{}),('sync_youtube_targets',{}),('owner_create_quiz',{'video_id':'00000000-0000-0000-0000-000000000000','title':'Permission check','question':{'prompt':'Check','options':['A','B'],'correct_index':0}})]:
    if not schema_ready:
        print(f'SKIP RPC access check {name}: schema is not ready')
        continue
    status,_=request('/rest/v1/rpc/'+name,'POST',body)
    passed=status in [401,403]
    print(('PASS' if passed else 'FAIL')+f' guest denied {name}: HTTP {status}')
    failed |= not passed
for name in ['sync-youtube','delete-account']:
    status,_=request('/functions/v1/'+name,'POST',{})
    passed=status==401
    print(('PASS' if passed else 'FAIL')+f' guest denied function {name}: HTTP {status}')
    failed |= not passed
status,data=request('/auth/v1/settings')
print('Authentication settings: HTTP',status)
if status==200:
    providers=data.get('external',{})
    print('Email provider enabled:',providers.get('email',False))
    print('Google provider enabled:',providers.get('google',False))
sys.exit(1 if failed else 0)
