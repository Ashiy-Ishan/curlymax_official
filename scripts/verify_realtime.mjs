// Local-only test of guest Realtime catalog changes and reconnect catch-up.
import { execFileSync } from 'node:child_process';
import { randomUUID } from 'node:crypto';
const c=JSON.parse(execFileSync('supabase',['status','-o','json'],{stdio:['ignore','pipe','ignore']}));
if(c.API_URL!=='http://127.0.0.1:55321') throw Error('CURLYmax local stack only');
const channel=randomUUID(), section=randomUUID(), video=randomUUID();
const headers={apikey:c.ANON_KEY,Authorization:`Bearer ${c.SERVICE_ROLE_KEY}`,'Content-Type':'application/json'};
async function write(table,body,method='POST',filter='') {
  const r=await fetch(`${c.API_URL}/rest/v1/${table}${filter}`,{method,headers,body:body?JSON.stringify(body):undefined});
  if(!r.ok) throw Error(`${table}: HTTP ${r.status}`);
}
let ws;
async function connect() {
  const url=c.API_URL.replace('http:','ws:')+`/realtime/v1/websocket?apikey=${c.ANON_KEY}&vsn=1.0.0`;
  ws=new WebSocket(url);
  await new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>reject(Error('Realtime subscription timeout')),20000);
    ws.onopen=()=>ws.send(JSON.stringify({topic:'realtime:catalog-check',event:'phx_join',ref:'1',payload:{config:{broadcast:{self:false},presence:{key:''},postgres_changes:[{event:'*',schema:'public',table:'channels'}]},access_token:c.ANON_KEY}}));
    ws.onmessage=({data})=>{ const m=JSON.parse(data); if(m.event==='system' && m.payload.status==='ok') {clearTimeout(timer);resolve();} };
    ws.onerror=()=>{clearTimeout(timer);reject(Error('Realtime socket failed'));};
  });
}
try {
  await connect();
  const arrived=new Promise((resolve,reject)=>{
    const timer=setTimeout(()=>reject(Error('No guest channel publication event')),15000);
    ws.onmessage=({data})=>{const m=JSON.parse(data);if(m.event==='postgres_changes' && m.payload.data.record.id===channel){clearTimeout(timer);resolve();}};
  });
  await write('channels',{id:channel,name:'CURLYmax Tech test',handle:`@tech-test-${channel}`});
  await arrived;
  console.log('PASS guest receives newly added channel through Realtime');
  ws.close();
  await write('sections',{id:section,channel_id:channel,name:'Test section'});
  await write('videos',{id:video,channel_id:channel,section_id:section,title:'Published while disconnected',youtube_url:'https://youtu.be/fq4N0hgOWzU',status:'published'});
  await connect();
  const response=await fetch(`${c.API_URL}/rest/v1/videos?id=eq.${video}`,{headers:{apikey:c.ANON_KEY,Authorization:`Bearer ${c.ANON_KEY}`}});
  const data=await response.json();
  if(!response.ok || data.length!==1) throw Error('Reconnect catalog missing published item');
  console.log('PASS guest catalog fetch after reconnect catches missed publication');
} finally {
  ws?.close();
  await write('videos',null,'DELETE',`?id=eq.${video}`);
  await write('sections',null,'DELETE',`?id=eq.${section}`);
  await write('channels',null,'DELETE',`?id=eq.${channel}`);
  execFileSync('docker',['exec','-i','supabase_db_curlymax','psql','-U','postgres','-d','postgres','-v','ON_ERROR_STOP=1','-c',`delete from private.notification_outbox where item_id='${video}'`],{stdio:'ignore'});
}
