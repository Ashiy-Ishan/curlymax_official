export type Event = { id: string; kind: string; item_id: string; title: string };
type Dependencies = {
  secret: string | undefined;
  accessToken: () => Promise<string>;
  claim: () => Promise<Event[]>;
  ready: (id: string) => Promise<Event | null>;
  send: (event: Event, token: string) => Promise<boolean>;
  finish: (id: string, succeeded: boolean, message: string) => Promise<void>;
  now?: () => number;
};
export function messageFor(event: Event) {
  return { message: {
    topic: 'curlymax_public',
    notification: { title: event.kind === 'quiz' ? 'New Video Quiz Available!' : 'A new video on CURLYmax', body: event.title },
    data: { kind: event.kind, item_id: event.item_id, event_id: event.id },
    android: { priority: 'HIGH', collapse_key: event.id,
      notification: { tag: event.id, channel_id: 'curlymax_updates' } },
  } };
}
export function createNotificationHandler(deps: Dependencies) {
  return async (request: Request): Promise<Response> => {
    if (request.method !== 'POST' || !deps.secret || request.headers.get('Authorization') !== `Bearer ${deps.secret}`) {
      return new Response('Unauthorized', { status: 401 });
    }
    const started = (deps.now ?? Date.now)();
    try {
      const token = await deps.accessToken();
      if (!token) throw new Error('OAuth unavailable');
      const events = await deps.claim();
      let sent = 0, failed = 0, persistenceFailures = 0;
      for (const event of events) {
        try {
          // Recheck immediately before an external side effect, not only when
          // the queue was claimed. FCM acceptance still is not device delivery.
          const current = await deps.ready(event.id);
          if (!current || (deps.now ?? Date.now)() - started > 100_000) {
            await deps.finish(event.id, false, 'Not sent: item unavailable or worker time budget exceeded');
            failed++;
            continue;
          }
          const accepted = await deps.send(current, token);
          await deps.finish(event.id, accepted, accepted ? 'Accepted by FCM' : 'FCM rejected the publication alert');
          if (accepted) sent++; else failed++;
        } catch {
          // Never blindly resend after a timeout or failed receipt write.
          failed++;
          try {
            await deps.finish(event.id, false, 'Ambiguous send or persistence failure; operator review required, no automatic retry');
          } catch { persistenceFailures++; }
        }
      }
      return Response.json({ sent, failed, persistence_failures: persistenceFailures }, { status: persistenceFailures ? 503 : 200 });
    } catch {
      return Response.json({ error: 'Worker setup or queue unavailable' }, { status: 503 });
    }
  };
}
