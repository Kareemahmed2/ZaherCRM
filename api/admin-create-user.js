// Vercel serverless function — creates Supabase Auth accounts on behalf of the single
// admin user. Self-service signup is intentionally not exposed anywhere in the app;
// this is the only way new accounts get created. Uses the Supabase service_role key
// (full-privilege, bypasses RLS) which must never reach the browser, so account
// creation has to happen here rather than client-side.
//
// Set as Vercel environment variables:
//   SUPABASE_SERVICE_ROLE_KEY (required) — Project Settings -> API -> service_role key
//   ADMIN_EMAIL               (required) — the one @zaher.ai account allowed to create others
const SUPABASE_URL = 'https://lzztbjjbtpuyatyxbrke.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_j4touVNQEgeB9jdyaQHsMg_t_n9w_4S';
const ALLOWED_DOMAIN = 'zaher.ai';

export default async function handler(req, res) {
  if (req.method !== 'POST') { res.status(405).json({ error: 'Method not allowed' }); return; }

  const serviceKey = process.env.SUPABASE_SERVICE_ROLE_KEY;
  const adminEmail = process.env.ADMIN_EMAIL;
  if (!serviceKey || !adminEmail) { res.status(500).json({ error: 'Admin account creation is not configured (missing SUPABASE_SERVICE_ROLE_KEY or ADMIN_EMAIL)' }); return; }

  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) { res.status(401).json({ error: 'Missing authorization' }); return; }

  try {
    // Verify the caller is a real, currently-logged-in Supabase user (not just any bearer string).
    const meRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { Authorization: `Bearer ${token}`, apikey: SUPABASE_ANON_KEY }
    });
    const me = await meRes.json();
    if (!meRes.ok || !me.email) { res.status(401).json({ error: 'Invalid or expired session' }); return; }
    if (me.email.toLowerCase() !== adminEmail.toLowerCase()) { res.status(403).json({ error: 'Only the admin account can create new accounts' }); return; }

    const { email, name, password } = req.body || {};
    if (!email || !name || !password) { res.status(400).json({ error: 'Name, email and password are required' }); return; }
    if (!email.toLowerCase().endsWith('@' + ALLOWED_DOMAIN)) { res.status(400).json({ error: `Only @${ALLOWED_DOMAIN} emails are allowed` }); return; }
    if (password.length < 6) { res.status(400).json({ error: 'Password must be at least 6 characters' }); return; }

    const createRes = await fetch(`${SUPABASE_URL}/auth/v1/admin/users`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json', apikey: serviceKey, Authorization: `Bearer ${serviceKey}` },
      body: JSON.stringify({ email, password, email_confirm: true, user_metadata: { name } })
    });
    const created = await createRes.json();
    if (!createRes.ok) { res.status(createRes.status).json({ error: created.msg || created.error_description || created.error || 'Failed to create account' }); return; }

    res.status(200).json({ email, password, name });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
}
