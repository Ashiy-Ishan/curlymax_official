import { test } from 'node:test';
import assert from 'node:assert/strict';
import { fetchCatalog } from '../supabase/functions/sync-youtube/youtube.ts';
import { authorizeSync } from '../supabase/functions/sync-youtube/auth.ts';
const channel = 'UCabcdefghijklmnopqrstuv';
const result = (items, more = {}) => Response.json({ items, ...more });
const channelResult = () => result([{ id: channel, contentDetails: { relatedPlaylists: { uploads: 'UPLOADS' } } }]);
test('auth rejects guests, invalid tokens and signed-in non-owners; owner and scheduler work', async () => {
  assert.equal(await authorizeSync('', undefined, async () => false, async () => true), 401);
  assert.equal(await authorizeSync('Bearer invalid', undefined, async () => false, async () => true), 401);
  assert.equal(await authorizeSync('Bearer viewer', 'secret', async () => true, async () => false), 403);
  assert.equal(await authorizeSync('Bearer owner', 'secret', async () => true, async () => true), 200);
  assert.equal(await authorizeSync('Bearer secret', 'secret', async () => { throw Error(); }, async () => false), 200);
  assert.equal(await authorizeSync('Bearer undefined', undefined, async () => false, async () => true), 401);
});
test('paginated uploads, batched metrics and memberships preserve actual publication dates; private/foreign videos excluded', async () => {
  const calls = [];
  const mock = async (input, options) => {
    const u = new URL(input); calls.push(u);
    assert.equal(u.origin, 'https://www.googleapis.com'); assert.equal(options.redirect, 'error');
    switch (u.pathname.split('/').at(-1)) {
      case 'channels': assert.equal(u.searchParams.get('forHandle'), '@ashiy_ish'); return channelResult();
      case 'playlistItems':
        if (u.searchParams.get('playlistId') === 'PL1234567890') return result([{ contentDetails: { videoId: 'newvideo001' } }]);
        return u.searchParams.has('pageToken') ? result([{ contentDetails: { videoId: 'newvideo002' } }, { contentDetails: { videoId: 'newvideo001' } }]) : result([{ contentDetails: { videoId: 'newvideo001' } }], { nextPageToken: 'second' });
      case 'videos':
        assert.equal(u.searchParams.get('id'), 'newvideo001,newvideo002');
        return result([
          { id: 'newvideo001', status: { privacyStatus: 'public' }, snippet: { channelId: channel, title: 'Video', publishedAt: '2026-01-01T00:00:00Z' }, statistics: { viewCount: '9007199254740993', likeCount: '9' } },
          { id: 'newvideo002', status: { privacyStatus: 'private' }, snippet: { channelId: channel } },
          { id: 'foreign0001', status: { privacyStatus: 'public' }, snippet: { channelId: 'OTHER' } },
        ]);
      case 'playlists': return result([{ id: 'PL1234567890', status: { privacyStatus: 'public' }, snippet: { title: 'List' } }]);
    }
    throw Error('Unexpected URL');
  };
  const data = await fetchCatalog('secret-api-key', null, '@ashiy_ish', mock);
  assert.equal(data.videos.length, 1); assert.equal(data.videos[0].view_count, '9007199254740993');
  assert.equal(data.videos[0].published_at, '2026-01-01T00:00:00Z');
  assert.deepEqual(data.playlists[0].video_ids, ['newvideo001']);
  assert.equal(calls.filter((u) => u.pathname.endsWith('/videos')).length, 1);
});
test('API failures expose neither provider bodies nor key-bearing URLs', async () => {
  await assert.rejects(fetchCatalog('secret-api-key', channel, '', async () => new Response('sensitive-provider-body', { status: 403 })), { message: 'YouTube quota or access denied' });
  await assert.rejects(fetchCatalog('secret-api-key', channel, '', async () => { throw Error('https://example?key=secret-api-key'); }), { message: 'YouTube temporarily unavailable' });
});
test('rejects excessive catalog rather than committing incomplete pagination', async () => {
  const mock = async (input) => new URL(input).pathname.endsWith('/channels') ? channelResult() : result(Array.from({ length: 50 }, (_, i) => ({ contentDetails: { videoId: `video${String(i).padStart(6, '0')}` } })), { nextPageToken: 'more' });
  await assert.rejects(fetchCatalog('key', channel, '', mock), { message: 'YouTube catalog exceeds supported import size' });
});
test('shared deadline stops upstream work before starting another request', async () => {
  let calls = 0;
  await assert.rejects(fetchCatalog('key', channel, '', async () => { calls++; return channelResult(); }, Date.now() - 1), { message: 'YouTube request budget exceeded' });
  assert.equal(calls, 0);
});
test('missing channel and malformed response are handled safely', async () => {
  await assert.rejects(fetchCatalog('key', null, 'missing', async () => result([])), { message: 'YouTube channel not found' });
  await assert.rejects(fetchCatalog('key', channel, '', async () => Response.json({ error: 'bad' })), { message: 'YouTube response invalid' });
});
