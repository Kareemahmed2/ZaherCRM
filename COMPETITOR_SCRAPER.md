# Competitor scanner — how it works and how it's integrated

Covers `scripts/competitor_scan.py`, `.github/workflows/competitor-scan.yml`, and
`api/trigger-competitor-scan.js` — the automated status/signal-detection system behind
the Competitors segment.

## Architecture (3 trigger paths, one script)

```
┌─────────────────────────────┐
│ 1. GitHub Actions cron       │  Mondays 06:00 UTC (automatic)
│ 2. GitHub Actions tab        │  "Run workflow" (manual, whole team)
│ 3. CRM "Check now" /         │  api/trigger-competitor-scan.js (Vercel)
│    "Check all now" buttons   │  → GitHub workflow_dispatch REST API
└──────────────┬───────────────┘
               ▼
   .github/workflows/competitor-scan.yml
               ▼
   scripts/competitor_scan.py  (runs on GitHub's Ubuntu runner)
               ▼
   Supabase REST API (service_role key, bypasses RLS)
   ── reads/writes `competitors` and `competitor_signals` tables
               ▼
   CRM reads the same tables live → Directory list, detail page,
   "needs review" signals queue
```

## Why it runs on GitHub, not Vercel

Scrapling's non-browser `Fetcher` class still requires `scrapling[fetchers]`, and that
extra hard-imports Playwright + Patchright even though they're never used —
`scrapling/engines/toolbelt/convertor.py` unconditionally does
`from playwright._impl._errors import Error`. Measured install size: 251MB, 214MB of it
dead Playwright/Patchright weight. That's over/at what fits in a Vercel Python
serverless function, so the actual scraping runs on a GitHub Actions runner instead,
which has no such size limit.

## The three ways it gets triggered

**1. Weekly, automatic** — `.github/workflows/competitor-scan.yml`:
```yaml
on:
  schedule:
    - cron: '0 6 * * 1'      # every Monday 06:00 UTC
  workflow_dispatch:
    inputs:
      competitor_id: {required: false, type: string}
```

**2. Manual, from GitHub** — anyone with repo access can go to the Actions tab →
"Competitor scan" → "Run workflow," optionally typing a specific `competitor_id` to
scope it to one competitor.

**3. On-demand, from the CRM** — this is the interesting one. Neither Vercel nor the
browser can call GitHub Actions directly (needs a secret token), so there's a small
relay function, `api/trigger-competitor-scan.js`:
- Verifies the caller is a logged-in `@zaher.ai` Supabase user (same auth check pattern
  as `api/admin-create-user.js`).
- `POST`s to
  `https://api.github.com/repos/Kareemahmed2/ZaherCRM/actions/workflows/competitor-scan.yml/dispatches`
  using a server-side GitHub PAT (`GITHUB_DISPATCH_TOKEN`, a Vercel env var — never
  sent to the browser).
- The CRM's `checkCompetitorNow()` (single competitor) and `checkAllCompetitorsNow()`
  (whole directory) both call this same endpoint — the only difference is whether
  `competitorId` is included in the POST body. Omit it → the script scans everyone,
  exactly like the weekly cron does.

This is fire-and-forget: the button just queues a GitHub Actions run and shows a toast
("check back in a minute or two") — it doesn't wait for the scan to finish or stream
results back.

## What the script actually does, per competitor

`scripts/competitor_scan.py`, run once for every row in `competitors` (or just one, if
`--competitor-id=N` was passed):

**Step 1 — Status check** (`check_status`):
```python
r = Fetcher.get(url, timeout=15, stealthy_headers=True, retries=1, follow_redirects=True)
return 'Operational' if r.status and 200 <= r.status < 400 else 'Inactive'
```
Scrapling's `Fetcher` does a plain HTTP GET (no browser, curl_cffi under the hood, with
browser-like headers to reduce trivial bot-blocking). Any exception — DNS failure, TLS
error, timeout — is caught and counted as `Inactive`. No `website` on file → `Unknown`,
no request made. The result is written straight back:
```python
sb_write('PATCH', f'competitors?id=eq.{c["id"]}', {'status': new_status, 'lastCheckedAt': now})
```

**Step 2 — Signal detection** (`detect_signals`):
- Fetches the competitor's `newsUrl` (falls back to `website` if none set) with the
  same `Fetcher.get`, then pulls the visible text out with
  `r.get_all_text(strip=True)`.
- Sends that text (truncated to 8,000 chars) to Groq with a system prompt asking it to
  extract funding/M&A/product/management/news items as strict JSON, with an explicit
  instruction to flag any mention of Jais or Falcon as top priority.
- Parses the response (stripping markdown code fences defensively), keeps only items
  with a valid `type` and non-empty `description`.
- Dedupes against everything already stored for that competitor (`is_duplicate` — same
  type + close text match) so re-running weekly doesn't re-queue the same finding
  forever.
- Anything new gets inserted as `{'detectedBy': 'scraper', 'confirmed': False, ...}` —
  landing straight in the "needs review" queue you confirm/dismiss in the CRM, never
  auto-published.

## Resilience details

- **Groq rate limits**: the free-tier account shares an 8K-tokens/minute ceiling with
  the live chatbot. Firing ~5 signal-extraction calls back to back can trip a 429 — the
  script retries up to 2 times, honoring the server's `Retry-After` header, capped at
  60s. This job runs unattended, so it can afford to wait where the live chatbot can't.
- **Everything fails soft, per-competitor**: a dead site, an unreachable news page, or
  a Groq error for one competitor just gets logged and skipped — it never aborts the
  whole batch. Next week's (or next on-demand) run tries again.
- **Auth**: the script uses `SUPABASE_SERVICE_ROLE_KEY` (bypasses RLS entirely) via raw
  `requests` calls to Supabase's PostgREST API — no SDK, matching how
  `api/admin-create-user.js` talks to Supabase.

## Secrets involved, and where they live

| Secret | Where | Used by |
|---|---|---|
| `SUPABASE_SERVICE_ROLE_KEY` | GitHub Actions secret | the script, to read/write competitors/signals |
| `GROQ_API_KEY` | GitHub Actions secret | the script, for signal extraction |
| `GITHUB_DISPATCH_TOKEN` | Vercel env var | `api/trigger-competitor-scan.js`, to call GitHub's dispatch API |

All three are already set — this setup was verified live (status checks, signal
extraction, and retry logic all confirmed working against real competitor sites).
