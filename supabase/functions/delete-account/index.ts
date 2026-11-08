import { createClient } from 'npm:@supabase/supabase-js@2';
import { authenticationTime, createDeleteAccountHandler } from './handler.ts';

const url = Deno.env.get('SUPABASE_URL');
const key = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY');
if (!url || !key) throw new Error('Account service configuration unavailable');
const db = createClient(url, key, {
  auth: { persistSession: false, autoRefreshToken: false },
});
Deno.serve(createDeleteAccountHandler({
  authenticatedUser: async (token) => {
    const { data, error } = await db.auth.getUser(token);
    if (error || !data.user) return null;
    const { data: claims, error: claimsError } = await db.auth.getClaims(token);
    if (claimsError || !claims || claims.claims.sub !== data.user.id) return null;
    return { id: data.user.id, authenticated_at: authenticationTime(claims.claims.amr) };
  },
  deleteUser: async (id) => {
    const { error } = await db.auth.admin.deleteUser(id, false);
    return !error;
  },
}));
