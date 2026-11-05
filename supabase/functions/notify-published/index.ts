import { createClient } from 'npm:@supabase/supabase-js@2';
import { importPKCS8, SignJWT } from 'npm:jose@6';

// Scheduled endpoint. Never expose SCHEDULER_SECRET or service-account credentials in Flutter.
Deno.serve(async (request) => {
  const secret = Deno.env.get('SCHEDULER_SECRET');
  if (request.method !== 'POST' || !secret || request.headers.get('Authorization') !== `Bearer ${secret}`) {
    return new Response('Unauthorized', { status: 401 });
  }
  const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!);
  try {
    const account = JSON.parse(Deno.env.get('FCM_SERVICE_ACCOUNT_JSON')!);
    const key = await importPKCS8(account.private_key, 'RS256');
    const assertion = await new SignJWT({ scope: 'https://www.googleapis.com/auth/firebase.messaging' })
      .setProtectedHeader({ alg: 'RS256', typ: 'JWT' }).setIssuer(account.client_email)
      .setAudience('https://oauth2.googleapis.com/token').setIssuedAt().setExpirationTime('55m').sign(key);
    const oauth = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion }),
      signal: AbortSignal.timeout(15000),
    });
    if (!oauth.ok) throw new Error('FCM OAuth failed');
    const { access_token } = await oauth.json();
    const { data: events, error } = await db.rpc('claim_notifications');
    if (error) throw error;
    let sent = 0, failed = 0;
    for (const event of events ?? []) {
      // No automatic HTTP retries: after a timeout, delivery is ambiguous. Review failures manually.
      try {
        const result = await fetch(`https://fcm.googleapis.com/v1/projects/${account.project_id}/messages:send`, {
          method: 'POST', headers: { Authorization: `Bearer ${access_token}`, 'Content-Type': 'application/json' },
          body: JSON.stringify({ message: {
            topic: 'curlymax_public',
            notification: { title: event.kind === 'video' ? 'A new video on CURLYmax' : 'A new quiz on CURLYmax', body: event.title },
            data: { kind: event.kind, item_id: event.item_id, event_id: event.id },
            android: { priority: 'HIGH', collapse_key: event.id, notification: { tag: event.id, channel_id: 'curlymax_updates' } },
          } }), signal: AbortSignal.timeout(15000),
        });
        const ok = result.ok;
        const finish = await db.rpc('finish_notification', { event: event.id, succeeded: ok, message: ok ? 'Accepted by FCM' : `FCM HTTP ${result.status}` });
        if (finish.error) throw finish.error;
        if (ok) sent++; else failed++;
      } catch (_) {
        await db.rpc('finish_notification', { event: event.id, succeeded: false, message: 'Ambiguous send or persistence failure; operator review required, no automatic retry' });
        failed++;
      }
    }
    return Response.json({ sent, failed });
  } catch (_) { return Response.json({ error: 'Worker setup or queue unavailable' }, { status: 500 }); }
});
