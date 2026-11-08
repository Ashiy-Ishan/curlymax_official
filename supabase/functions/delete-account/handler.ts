type VerifiedUser = { id: string; authenticated_at: number | null };
type Dependencies = {
  authenticatedUser: (token: string) => Promise<VerifiedUser | null>;
  deleteUser: (id: string) => Promise<boolean>;
  now?: () => number;
};
const cors = {
  'Access-Control-Allow-Origin': '*',
  'Access-Control-Allow-Headers': 'authorization, apikey, content-type, x-client-info',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
};
const reply = (value: unknown, status = 200) =>
  Response.json(value, { status, headers: { ...cors, 'Cache-Control': 'no-store' } });

// Read only from cryptographically verified claims for this exact caller token.
// A token refresh, or sign-in on another device, is not reauthentication here.
export function authenticationTime(amr: unknown): number | null {
  if (!Array.isArray(amr)) return null;
  const methods = new Set(['password', 'oauth', 'otp', 'totp', 'magiclink', 'sso/saml', 'oauth_provider/authorization_code']);
  const timestamps = amr.filter((entry) => entry && methods.has(entry.method) &&
    typeof entry.timestamp === 'number' && Number.isFinite(entry.timestamp) && entry.timestamp > 0)
    .map((entry) => entry.timestamp * 1000);
  return timestamps.length ? Math.max(...timestamps) : null;
}

export function createDeleteAccountHandler(dependencies: Dependencies) {
  return async (request: Request): Promise<Response> => {
    if (request.method === 'OPTIONS') return new Response(null, { headers: cors });
    if (request.method !== 'POST') return reply({ error: 'Use POST' }, 405);
    const authorization = request.headers.get('Authorization') ?? '';
    if (!authorization.startsWith('Bearer ') || authorization.length > 8192) {
      return reply({ error: 'Sign in required' }, 401);
    }
    try {
      // Never accept a user ID from the body, query, JWT payload decoding, or
      // user-editable metadata. Supabase Auth must verify the live identity.
      const user = await dependencies.authenticatedUser(authorization.slice(7));
      if (!user) return reply({ error: 'Sign in required' }, 401);
      const signedInAt = user.authenticated_at;
      const now = (dependencies.now ?? Date.now)();
      if (signedInAt === null || !Number.isFinite(signedInAt) || signedInAt > now + 60_000 || now - signedInAt > 15 * 60_000) {
        return reply({ error: 'Sign out and sign in again before deleting your account.', code: 'recent_sign_in_required' }, 403);
      }
      const text = await request.text();
      if (text.length > 1024) return reply({ error: 'Request too large' }, 413);
      let body;
      try { body = JSON.parse(text); } catch { return reply({ error: 'Confirm deletion' }, 400); }
      if (!body || Array.isArray(body) || typeof body !== 'object' ||
          Object.keys(body).length !== 1 || body.confirmation !== 'DELETE') {
        return reply({ error: 'Confirm deletion with DELETE' }, 400);
      }
      if (!await dependencies.deleteUser(user.id)) {
        return reply({ error: 'Account could not be deleted. Your data has not been confirmed deleted.' }, 500);
      }
      return reply({ deleted: true });
    } catch {
      // Do not return service credentials, raw provider errors or tokens.
      return reply({ error: 'Deletion could not be confirmed. Check your connection and try signing in again.' }, 500);
    }
  };
}
