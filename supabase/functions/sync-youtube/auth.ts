// Callbacks verify with Supabase Auth and the owner-membership RPC, respectively.
export async function authorizeSync(
  authorization: string,
  schedulerSecret: string | undefined,
  verifyUser: (token: string) => Promise<boolean>,
  verifyOwner: () => Promise<boolean>,
): Promise<200 | 401 | 403> {
  if (schedulerSecret && authorization === `Bearer ${schedulerSecret}`) return 200;
  if (!authorization.startsWith('Bearer ') || authorization.length > 8192) return 401;
  try {
    if (!await verifyUser(authorization.slice(7))) return 401;
    return await verifyOwner() ? 200 : 403;
  } catch { return 401; }
}
