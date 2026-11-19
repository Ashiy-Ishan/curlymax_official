import { createClient } from 'npm:@supabase/supabase-js@2';
import { importPKCS8, SignJWT } from 'npm:jose@6';
import { createNotificationHandler, messageFor, type Event } from './handler.ts';

const db = createClient(Deno.env.get('SUPABASE_URL')!, Deno.env.get('SUPABASE_SERVICE_ROLE_KEY')!, {
  auth: { persistSession: false, autoRefreshToken: false },
});
let projectId = '';
Deno.serve(createNotificationHandler({
  secret: Deno.env.get('SCHEDULER_SECRET'),
  accessToken: async () => {
    const account = JSON.parse(Deno.env.get('FCM_SERVICE_ACCOUNT_JSON') ?? '{}');
    if (!/^[a-z][a-z0-9-]{4,62}$/.test(account.project_id ?? '')) throw new Error('Invalid Firebase project');
    projectId = account.project_id;
    const key = await importPKCS8(account.private_key, 'RS256');
    const assertion = await new SignJWT({ scope: 'https://www.googleapis.com/auth/firebase.messaging' })
      .setProtectedHeader({ alg: 'RS256', typ: 'JWT' }).setIssuer(account.client_email)
      .setAudience('https://oauth2.googleapis.com/token').setIssuedAt().setExpirationTime('55m').sign(key);
    const response = await fetch('https://oauth2.googleapis.com/token', {
      method: 'POST', headers: { 'Content-Type': 'application/x-www-form-urlencoded' },
      body: new URLSearchParams({ grant_type: 'urn:ietf:params:oauth:grant-type:jwt-bearer', assertion }),
      signal: AbortSignal.timeout(15000), redirect: 'error',
    });
    if (!response.ok) throw new Error('OAuth rejected');
    const value = await response.json();
    return typeof value.access_token === 'string' ? value.access_token : '';
  },
  claim: async () => {
    const { data, error } = await db.rpc('claim_notifications');
    if (error) throw error;
    return data ?? [];
  },
  ready: async (id) => {
    const { data, error } = await db.rpc('notification_ready', { event: id });
    if (error) throw error;
    return data;
  },
  send: async (event: Event, token: string) => {
    const response = await fetch(`https://fcm.googleapis.com/v1/projects/${projectId}/messages:send`, {
      method: 'POST', headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
      body: JSON.stringify(messageFor(event)), signal: AbortSignal.timeout(10000), redirect: 'error',
    });
    return response.ok;
  },
  finish: async (event, succeeded, message) => {
    const { error } = await db.rpc('finish_notification', { event, succeeded, message });
    if (error) throw error;
  },
}));
