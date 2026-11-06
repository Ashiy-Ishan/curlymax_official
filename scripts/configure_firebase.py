#!/usr/bin/env python3
"""Import PUBLIC Android Firebase settings into ignored config/live.json."""
import json,sys
from pathlib import Path
root=Path(__file__).resolve().parents[1]
source=Path(sys.argv[1]) if len(sys.argv)>1 else root/'config/google-services.json'
if not source.exists():sys.exit('Save the Android Firebase google-services.json to config/google-services.json first.')
data=json.loads(source.read_text())
if 'private_key' in data or data.get('type')=='service_account':
    sys.exit('Refusing a service-account key. Use the public Android google-services.json instead.')
client=next((c for c in data.get('client',[]) if c.get('client_info',{}).get('android_client_info',{}).get('package_name')=='com.curlymax.app'),None)
if client is None:sys.exit('No Firebase Android client matches package com.curlymax.app.')
project=data['project_info'];info=client['client_info']
settings={
 'FCM_ENABLED':True,'FIREBASE_API_KEY':client['api_key'][0]['current_key'],
 'FIREBASE_APP_ID':info['mobilesdk_app_id'],'FIREBASE_SENDER_ID':project['project_number'],
 'FIREBASE_PROJECT_ID':project['project_id'],
}
target=root/'config/live.json'
if not target.exists():sys.exit('Create config/live.json with your public Supabase settings first.')
config=json.loads(target.read_text());config.update(settings)
target.write_text(json.dumps(config,indent=2)+'\n')
print('Public Android Firebase settings imported. Rebuild the app to enable opt-in notifications.')
