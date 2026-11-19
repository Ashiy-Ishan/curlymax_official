import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createNotificationHandler, messageFor } from '../supabase/functions/notify-published/handler.ts';
const event = { id: 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa', kind: 'quiz', item_id: 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb', title: 'Quiz title' };
const request = (secret = 'scheduler-secret') => new Request('https://example.test/worker', { method: 'POST', headers: { Authorization: `Bearer ${secret}` } });
function fixture(overrides = {}) {
  const calls = { oauth: 0, claims: 0, sends: [], receipts: [] };
  const handler = createNotificationHandler({
    secret: 'scheduler-secret',
    accessToken: async () => { calls.oauth++; return 'server-only-token'; },
    claim: async () => { calls.claims++; return [event]; },
    ready: async () => event,
    send: async (item) => { calls.sends.push(item); return true; },
    finish: async (...args) => { calls.receipts.push(args); },
    ...overrides,
  });
  return { handler, calls };
}
test('unauthorized requests do no OAuth, claiming or sending', async () => {
  const { handler, calls } = fixture();
  assert.equal((await handler(request('wrong'))).status, 401);
  assert.equal((await handler(new Request('https://example.test'))).status, 401);
  assert.equal(calls.oauth, 0); assert.equal(calls.claims, 0); assert.deepEqual(calls.sends, []);
});
test('quiz payload uses only the public topic and validated item destination', () => {
  const value = messageFor(event).message;
  assert.equal(value.topic, 'curlymax_public');
  assert.equal(value.notification.title, 'New Video Quiz Available!');
  assert.deepEqual(value.data, { kind: 'quiz', item_id: event.item_id, event_id: event.id });
  assert.equal(value.android.notification.tag, event.id);
});
test('successful publication is claimed and sent once; acceptance is persisted', async () => {
  const { handler, calls } = fixture();
  const result = await handler(request());
  assert.deepEqual(await result.json(), { sent: 1, failed: 0, persistence_failures: 0 });
  assert.equal(calls.claims, 1); assert.equal(calls.sends.length, 1);
  assert.deepEqual(calls.receipts, [[event.id, true, 'Accepted by FCM']]);
});
test('unpublished-after-claim item is not sent', async () => {
  const { handler, calls } = fixture({ ready: async () => null });
  const result = await handler(request());
  assert.equal((await result.json()).failed, 1); assert.equal(calls.sends.length, 0);
  assert.equal(calls.receipts[0][1], false);
});
test('FCM rejection is recorded without a resend', async () => {
  let sends = 0;
  const { handler, calls } = fixture({ send: async () => { sends++; return false; } });
  const result = await handler(request());
  assert.equal((await result.json()).failed, 1); assert.equal(sends, 1);
  assert.equal(calls.receipts[0][1], false);
});
test('ambiguous timeout is not retried and does not expose raw errors', async () => {
  let sends = 0;
  const { handler, calls } = fixture({ send: async () => { sends++; throw Error('sensitive-transport-detail'); } });
  const result = await handler(request());
  assert.equal(sends, 1); assert.doesNotMatch(await result.text(), /sensitive-transport-detail/);
  assert.match(calls.receipts[0][2], /operator review/);
});
test('receipt write failure reports service failure instead of false success', async () => {
  const { handler, calls } = fixture({ finish: async () => { throw Error('private database detail'); } });
  const result = await handler(request());
  assert.equal(result.status, 503);
  assert.deepEqual(await result.json(), { sent: 0, failed: 1, persistence_failures: 1 });
  assert.equal(calls.sends.length, 1);
});
test('OAuth failure leaves the queue unclaimed', async () => {
  const { handler, calls } = fixture({ accessToken: async () => { throw Error('sensitive-key'); } });
  const result = await handler(request());
  assert.equal(result.status, 503); assert.equal(calls.claims, 0);
  assert.doesNotMatch(await result.text(), /sensitive-key/);
});
