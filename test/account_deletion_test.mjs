import { test } from 'node:test';
import assert from 'node:assert/strict';
import { authenticationTime, createDeleteAccountHandler } from '../supabase/functions/delete-account/handler.ts';

const now = Date.parse('2026-11-08T00:00:00Z');
const request = (body = { confirmation: 'DELETE' }, token = 'verified-user') => new Request('https://example.test/delete-account', {
  method: 'POST', headers: { Authorization: `Bearer ${token}` }, body: JSON.stringify(body),
});
function fixture(overrides = {}) {
  const deleted = [];
  const handler = createDeleteAccountHandler({
    authenticatedUser: async (token) => token === 'verified-user' ? { id: 'user-A', authenticated_at: now - 60_000 } : null,
    deleteUser: async (id) => { deleted.push(id); return true; },
    now: () => now, ...overrides,
  });
  return { handler, deleted };
}

test('guest and invalid tokens cannot delete an account', async () => {
  const { handler, deleted } = fixture();
  assert.equal((await handler(new Request('https://example.test', { method: 'POST' }))).status, 401);
  assert.equal((await handler(request(undefined, 'invalid'))).status, 401);
  assert.deepEqual(deleted, []);
});
test('only the verified caller can be deleted, after exact confirmation', async () => {
  const { handler, deleted } = fixture();
  assert.equal((await handler(request({ confirmation: 'DELETE', user_id: 'user-B' }))).status, 400);
  assert.equal((await handler(request({ confirmation: 'delete' }))).status, 400);
  assert.deepEqual(deleted, []);
  const result = await handler(request());
  assert.equal(result.status, 200);
  assert.deepEqual(await result.json(), { deleted: true });
  assert.deepEqual(deleted, ['user-A']);
});
test('session authentication timestamps reject stale, missing and future authentication', async () => {
  for (const authenticated_at of [null, now - 16 * 60_000, now + 120_000, NaN]) {
    const { handler, deleted } = fixture({ authenticatedUser: async () => ({ id: 'user-A', authenticated_at, last_sign_in_at: new Date(now).toISOString() }) });
    const result = await handler(request());
    assert.equal(result.status, 403);
    assert.equal((await result.json()).code, 'recent_sign_in_required');
    assert.deepEqual(deleted, []);
  }
});
test('refresh claims do not replace the original authentication time', () => {
  const old = now / 1000 - 3600;
  assert.equal(authenticationTime([{ method: 'password', timestamp: old }, { method: 'token_refresh', timestamp: now / 1000 }]), old * 1000);
  assert.equal(authenticationTime([{ method: 'oauth', timestamp: now / 1000 }]), now);
  assert.equal(authenticationTime([{ method: 'token_refresh', timestamp: now / 1000 }]), null);
  assert.equal(authenticationTime([{ method: 'password', timestamp: 'forged' }]), null);
  assert.equal(authenticationTime(undefined), null);
});
test('provider failure cannot claim success or expose credentials', async () => {
  const { handler } = fixture({ deleteUser: async () => { throw Error('sensitive-server-key'); } });
  const result = await handler(request());
  assert.equal(result.status, 500);
  assert.doesNotMatch(await result.text(), /sensitive-server-key|deleted.*true/);
});
