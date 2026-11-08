import { createClient } from 'npm:@supabase/supabase-js@2';
import { fetchCatalog } from './youtube.ts';
import { authorizeSync } from './auth.ts';

const cors = { 'Access-Control-Allow-Origin': '*', 'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info', 'Access-Control-Allow-Methods': 'POST, OPTIONS' };
const reply = (value: unknown, status = 200) => Response.json(value, { status, headers: cors });
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// Gateway JWT checking is disabled because scheduled calls use a distinct secret.
// Every non-scheduler caller is verified with Auth, then the owner-only RPC.
Deno.serve(async (request) => {
  if (request.method === 'OPTIONS') return new Response(null, { headers: cors });
  if (request.method !== 'POST') return reply({ error: 'Use POST' }, 405);
  const url = Deno.env.get('SUPABASE_URL');
  const serviceKey = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
  const apiKey = Deno.env.get('YOUTUBE_API_KEY');
  if (!url || !serviceKey) return reply({ error: 'Server configuration unavailable' }, 503);
  const bearer = request.headers.get('Authorization') ?? '';
  const schedulerSecret = Deno.env.get('YOUTUBE_SYNC_SECRET');
  const auth = createClient(url, serviceKey, { global: { headers: { Authorization: bearer } }, auth: { persistSession: false, autoRefreshToken: false } });
  const authorization = await authorizeSync(bearer, schedulerSecret,
    async (token) => { const { data, error } = await auth.auth.getUser(token); return !error && !!data.user; },
    async () => { const owner = await auth.rpc('is_owner'); return !owner.error && owner.data === true; });
  if (authorization !== 200) return reply({ error: authorization === 403 ? 'Owner only' : 'Unauthorized' }, authorization);
  if (!apiKey) return reply({ error: 'Configure server YOUTUBE_API_KEY first' }, 503);
  let target: string | undefined;
  try {
    const text = await request.text();
    if (text.length > 1024) return reply({ error: 'Request too large' }, 413);
    const body = text ? JSON.parse(text) : {};
    if (!body || typeof body !== 'object' || Array.isArray(body)) throw new Error();
    if (body.channel_id !== undefined) {
      if (typeof body.channel_id !== 'string' || !uuid.test(body.channel_id)) throw new Error();
      target = body.channel_id;
    }
  } catch { return reply({ error: 'Provide an optional channel_id UUID' }, 400); }
  const db = createClient(url, serviceKey, { auth: { persistSession: false, autoRefreshToken: false } });
  const targets = target ? { data: [target], error: null } : await db.rpc('sync_youtube_targets');
  if (targets.error) return reply({ error: 'Sync settings unavailable' }, 500);
  // Oldest-sync-first rotation and a shared deadline keep scheduled batches bounded.
  const deadline = Date.now() + 100_000;
  const results: unknown[] = [];
  for (const channelId of (targets.data ?? []).slice(0, 5)) {
    if (Date.now() > deadline - 15_000) { results.push({ channel_id: channelId, skipped: true, reason: 'Batch time budget; next scheduled run will continue' }); break; }
    const token = crypto.randomUUID();
    const claim = await db.rpc('sync_youtube_claim', { target: channelId, token });
    if (claim.error) { results.push({ channel_id: channelId, error: 'Sync settings or section unavailable' }); continue; }
    if (!claim.data) { results.push({ channel_id: channelId, skipped: true }); continue; }
    try {
      const catalog = await fetchCatalog(apiKey, claim.data.youtube_channel_id, claim.data.handle, fetch, deadline);
      const applied = await db.rpc('sync_youtube_apply', { target: channelId, token, resolved_channel: catalog.channelId, videos: catalog.videos, playlists: catalog.playlists });
      if (applied.error) throw new Error('Catalog validation or database commit failed');
      if (catalog.channelLogoUrl) {
        const logo = await db.rpc('sync_youtube_channel_avatar', {
          target: channelId, resolved_channel: catalog.channelId, logo_url: catalog.channelLogoUrl,
        });
        if (logo.error) {
          // Content is already committed; do not report the whole import as
          // failed or return raw database/provider details for an icon issue.
          results.push({ ...applied.data, logo_updated: false });
          continue;
        }
      }
      results.push(applied.data);
    } catch (error) {
      // Only locally generated safe messages are used; never log provider body,
      // URL (which contains API key), raw fetch errors, credentials, or JWTs.
      const safeMessages = new Set(['YouTube quota or access denied', 'YouTube temporarily unavailable', 'YouTube channel not found', 'YouTube catalog exceeds supported import size', 'YouTube request budget exceeded', 'YouTube response invalid', 'Catalog validation or database commit failed']);
      const message = error instanceof Error && safeMessages.has(error.message) ? error.message : 'YouTube sync failed; retry later';
      await db.rpc('sync_youtube_fail', { target: channelId, token, message });
      results.push({ channel_id: channelId, error: message });
    }
  }
  return reply({ results });
});
