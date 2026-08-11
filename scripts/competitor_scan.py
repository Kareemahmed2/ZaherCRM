#!/usr/bin/env python3
"""
Weekly competitor scan for Zaher CRM's Competitors segment.

For each competitor: checks whether their website is still up (writes `status` +
`lastCheckedAt`), then fetches their news/press page (or their homepage as a fallback)
and asks Groq to pull out any competitive signals -- funding, M&A, product launches,
management changes, or general news -- inserting them as unconfirmed `competitor_signals`
rows for a team member to review in the app.

Runs on a schedule via .github/workflows/competitor-scan.yml (weekly) -- NOT on Vercel.
Scrapling's fetchers module hard-imports Playwright/Patchright regardless of which
fetcher class you use (confirmed by installing it: ~251MB, ~214MB of which is
Playwright/Patchright we never actually use, since we only need the lightweight
non-browser Fetcher). That's over/at Vercel's serverless function size ceiling, so this
runs on GitHub Actions instead, which has no such limit. See
[[project-competitors-segment]] memory / the Competitors plan for the full reasoning.

Can also be pointed at a single competitor via --competitor-id=N, which is how the
in-app "Check now" button triggers an on-demand run (see api/trigger-competitor-scan.js).

Required environment variables:
  SUPABASE_SERVICE_ROLE_KEY  -- bypasses RLS; same key api/admin-create-user.js uses.
                                 NEVER commit this -- set as a GitHub Actions secret.
  GROQ_API_KEY               -- same key api/chat.js uses. Set as a GitHub Actions secret.
Optional:
  SUPABASE_URL   -- defaults to the project URL hardcoded in zaher_crm.html (not a
                    secret -- it's the public REST endpoint, same as the anon key's host).
  GROQ_MODEL     -- defaults to the same model api/chat.js uses.
"""
import json
import os
import re
import sys
import time
from datetime import datetime, timezone

import requests
from scrapling.fetchers import Fetcher

SUPABASE_URL = os.environ.get('SUPABASE_URL', 'https://lzztbjjbtpuyatyxbrke.supabase.co').strip()
SERVICE_KEY = os.environ['SUPABASE_SERVICE_ROLE_KEY'].strip()
GROQ_API_KEY = os.environ.get('GROQ_API_KEY', '').strip() or None
GROQ_MODEL = os.environ.get('GROQ_MODEL', 'openai/gpt-oss-120b').strip()

SB_HEADERS = {
    'apikey': SERVICE_KEY,
    'Authorization': f'Bearer {SERVICE_KEY}',
    'Content-Type': 'application/json',
}
SIGNAL_TYPES = {'Funding', 'M&A', 'Product', 'Management Change', 'News'}


def sb_get(path, params=None):
    r = requests.get(f'{SUPABASE_URL}/rest/v1/{path}', headers=SB_HEADERS, params=params, timeout=20)
    r.raise_for_status()
    return r.json()


def sb_write(method, path, payload):
    h = {**SB_HEADERS, 'Prefer': 'return=minimal'}
    r = requests.request(method, f'{SUPABASE_URL}/rest/v1/{path}', headers=h, json=payload, timeout=20)
    r.raise_for_status()


def normalize_url(raw):
    raw = (raw or '').strip()
    if not raw:
        return None
    return raw if raw.startswith('http') else f'https://{raw}'


def check_status(company, website):
    """Health-check one competitor's site with Scrapling's lightweight (non-browser)
    Fetcher. Any network-level failure (SSL, DNS, timeout, connection refused, ...)
    is treated as Inactive -- curl_cffi raises several different exception types for
    these, so a broad except is the right call here rather than enumerating each one."""
    url = normalize_url(website)
    if not url:
        return 'Unknown'
    try:
        r = Fetcher.get(url, timeout=15, stealthy_headers=True, retries=1, follow_redirects=True)
        return 'Operational' if r.status and 200 <= r.status < 400 else 'Inactive'
    except Exception as e:
        print(f'  status check failed for {company} ({url}): {type(e).__name__}: {e}')
        return 'Inactive'


def groq_extract_signals(company, text):
    """Ask Groq to pull structured competitive signals out of scraped page text.
    Returns [] on any failure -- a broken extraction this week just means no new
    signals get queued, not a script crash; next week's run tries again."""
    if not GROQ_API_KEY or not text:
        return []
    text = text[:8000]  # keep the prompt small -- same token-budget discipline as api/chat.js
    system = (
        'You extract competitive-intelligence signals from a webpage\'s text for a company '
        'tracking its GEO/AI-visibility competitors in the MENA region. Given raw page text '
        f'from {company}\'s website, list any recent funding, M&A, product launches or '
        'updates, management changes, or notable news. Pay special attention to any mention '
        'of Jais or Falcon (Arabic-first sovereign AI models) -- that is the single '
        'highest-priority signal to catch, above anything else. Respond with ONLY a JSON '
        'array (no prose, no code fence), each item shaped as '
        '{"type": one of "Funding"/"M&A"/"Product"/"Management Change"/"News", '
        '"description": one sentence, "occurred_on": "YYYY-MM-DD" or null if unknown}. '
        'Return an empty array if nothing notable is in the text.'
    )
    # Groq's free-tier TPM limit is tiny (8K/min, see [[project-chatbot-groq-rate-limits]]) and a
    # weekly batch of ~14 back-to-back calls trips it -- retry on 429 using the server's own
    # Retry-After, same pattern as fetchChat() in zaher_crm.html, but with more attempts and a
    # higher wait ceiling than the live chatbot since this runs unattended in the background and
    # has no user waiting on a reply -- confirmed live that one retry isn't always enough (two
    # competitors' Groq calls can land in the same rate-limit window back to back).
    MAX_ATTEMPTS = 3
    for attempt in range(MAX_ATTEMPTS):
        try:
            resp = requests.post(
                'https://api.groq.com/openai/v1/chat/completions',
                headers={'Authorization': f'Bearer {GROQ_API_KEY}', 'Content-Type': 'application/json'},
                json={
                    'model': GROQ_MODEL,
                    'messages': [
                        {'role': 'system', 'content': system},
                        {'role': 'user', 'content': text},
                    ],
                    'max_tokens': 800,
                },
                timeout=30,
            )
            if resp.status_code == 429 and attempt < MAX_ATTEMPTS - 1:
                wait = min(max(float(resp.headers.get('Retry-After', 5)), 1), 60)
                print(f'  Groq rate-limited for {company}, retrying in {wait:.0f}s...')
                time.sleep(wait)
                continue
            resp.raise_for_status()
            content = resp.json()['choices'][0]['message']['content'].strip()
            # Models sometimes wrap JSON in a code fence despite being told not to -- strip it
            # defensively rather than letting json.loads() choke on it.
            content = re.sub(r'^```(?:json)?\s*|\s*```$', '', content)
            items = json.loads(content)
            return [i for i in items if isinstance(i, dict) and i.get('type') in SIGNAL_TYPES and i.get('description')]
        except Exception as e:
            print(f'  Groq signal extraction failed for {company}: {type(e).__name__}: {e}')
            return []
    return []


def is_duplicate(existing, candidate):
    """Cheap dedup so re-running weekly doesn't re-queue the same signal forever --
    same type plus a close text match against anything already stored for this competitor."""
    cand_desc = candidate['description'].strip().lower()
    for s in existing:
        if s.get('type') != candidate['type']:
            continue
        existing_desc = (s.get('description') or '').strip().lower()
        if existing_desc == cand_desc or (len(cand_desc) > 20 and cand_desc[:20] in existing_desc):
            return True
    return False


def detect_signals(competitor, existing_signals):
    url = normalize_url(competitor.get('newsUrl') or competitor.get('website'))
    if not url:
        return []
    try:
        r = Fetcher.get(url, timeout=15, stealthy_headers=True, retries=1, follow_redirects=True)
        text = r.get_all_text(strip=True)
    except Exception as e:
        print(f'  signal fetch failed for {competitor["company"]} ({url}): {type(e).__name__}: {e}')
        return []
    candidates = groq_extract_signals(competitor['company'], text)
    new_signals = []
    for cand in candidates:
        if is_duplicate(existing_signals, cand):
            continue
        new_signals.append({
            'competitor_id': competitor['id'],
            'type': cand['type'],
            'description': cand['description'][:500],
            'occurred_on': cand.get('occurred_on') or None,
            'detectedBy': 'scraper',
            'confirmed': False,
        })
    return new_signals


def main():
    competitor_id = None
    for arg in sys.argv[1:]:
        if arg.startswith('--competitor-id='):
            competitor_id = arg.split('=', 1)[1].strip()

    params = {'select': '*'}
    if competitor_id:
        params['id'] = f'eq.{competitor_id}'
    competitors = sb_get('competitors', params)
    print(f'Scanning {len(competitors)} competitor(s){" (single, on-demand)" if competitor_id else " (weekly full scan)"}...')

    for c in competitors:
        print(f'- {c["company"]}')

        new_status = check_status(c['company'], c.get('website'))
        sb_write('PATCH', f'competitors?id=eq.{c["id"]}', {
            'status': new_status,
            'lastCheckedAt': datetime.now(timezone.utc).isoformat(),
        })
        print(f'  status -> {new_status}')

        existing = sb_get('competitor_signals', {'select': 'type,description', 'competitor_id': f'eq.{c["id"]}'})
        new_signals = detect_signals(c, existing)
        for s in new_signals:
            sb_write('POST', 'competitor_signals', s)
        if new_signals:
            print(f'  +{len(new_signals)} new signal(s) queued for review')

    print('Done.')


if __name__ == '__main__':
    main()
