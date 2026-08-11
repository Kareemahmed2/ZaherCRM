// Vercel serverless function — lets the in-app "Check now" button on a competitor's
// detail page kick off scripts/competitor_scan.py on demand, instead of waiting for
// the weekly GitHub Actions schedule (.github/workflows/competitor-scan.yml).
//
// Dispatches that workflow via GitHub's REST API using a server-side token, so the
// token (which needs `actions:write` on the repo) never reaches the browser.
//
// Set as a Vercel environment variable:
//   GITHUB_DISPATCH_TOKEN (required) — a GitHub PAT (classic "repo" scope, or a
//                                        fine-grained token with Actions: Read and write)
const SUPABASE_URL = 'https://lzztbjjbtpuyatyxbrke.supabase.co';
const SUPABASE_ANON_KEY = 'sb_publishable_j4touVNQEgeB9jdyaQHsMg_t_n9w_4S';
const ALLOWED_DOMAIN = 'zaher.ai';
const GITHUB_OWNER = 'Kareemahmed2';
const GITHUB_REPO = 'ZaherCRM';
const WORKFLOW_FILE = 'competitor-scan.yml';

export default async function handler(req, res) {
  if (req.method !== 'POST') { res.status(405).json({ error: 'Method not allowed' }); return; }

  const ghToken = process.env.GITHUB_DISPATCH_TOKEN;
  if (!ghToken) { res.status(500).json({ error: 'On-demand scans are not configured (missing GITHUB_DISPATCH_TOKEN)' }); return; }

  const token = (req.headers.authorization || '').replace(/^Bearer\s+/i, '');
  if (!token) { res.status(401).json({ error: 'Missing authorization' }); return; }

  try {
    // Verify the caller is a real, currently-logged-in Zaher team member (same check
    // pattern as api/admin-create-user.js) -- any @zaher.ai account can trigger a check,
    // not just the admin, since this is a read-only-ish "refresh this competitor" action.
    const meRes = await fetch(`${SUPABASE_URL}/auth/v1/user`, {
      headers: { Authorization: `Bearer ${token}`, apikey: SUPABASE_ANON_KEY }
    });
    const me = await meRes.json();
    if (!meRes.ok || !me.email) { res.status(401).json({ error: 'Invalid or expired session' }); return; }
    if (!me.email.toLowerCase().endsWith('@' + ALLOWED_DOMAIN)) { res.status(403).json({ error: 'Not authorized' }); return; }

    const { competitorId } = req.body || {};

    const dispatchRes = await fetch(
      `https://api.github.com/repos/${GITHUB_OWNER}/${GITHUB_REPO}/actions/workflows/${WORKFLOW_FILE}/dispatches`,
      {
        method: 'POST',
        headers: {
          'Content-Type': 'application/json',
          Authorization: `Bearer ${ghToken}`,
          Accept: 'application/vnd.github+json'
        },
        body: JSON.stringify({
          ref: 'master',
          inputs: competitorId ? { competitor_id: String(competitorId) } : {}
        })
      }
    );

    if (!dispatchRes.ok) {
      const detail = await dispatchRes.text();
      res.status(dispatchRes.status).json({ error: `GitHub dispatch failed: ${detail}` });
      return;
    }

    res.status(200).json({ ok: true });
  } catch (e) {
    res.status(500).json({ error: e.message });
  }
}
