#!/usr/bin/env python3
"""
Export the current competitor directory from Supabase to research/roster.json.

This is what lets the weekly research run stop carrying a hand-written baseline. Instead of
23 companies typed into the scheduled prompt — which goes stale the moment anything changes,
and grows without bound as the directory does — the run fetches this file and diffs against
what is actually stored.

That closes the loop:

    Mon 06:00  competitor-scan.yml  ->  scraper checks sites, then exports roster.json
    Mon 08:00  Cowork research run  ->  reads roster.json, researches, emits a delta CSV
    on push    apply-research.yml   ->  applies the delta to Supabase
    next Mon   roster.json regenerates from the updated DB

Nobody hand-maintains a baseline again, and adding a competitor to the CRM automatically puts
it in next week's scan.

Two things this file is careful about:

1. It emits the CURRENT STORED VALUE of every field the research pass may overwrite. The delta
   rule ("only write a cell whose value actually changed") is only enforceable if the researcher
   can see what is already there. Truncating prose would cause unchanged fields to be rewritten
   with a worse paraphrase — the exact failure the blank-cell rule exists to prevent. Use
   --compact only if size becomes a real problem, and accept that tradeoff knowingly.
2. Radar nulls are preserved as null, never coerced to 0. Null means NOT MEASURED.

Usage:
  python scripts/export_roster.py                       # -> research/roster.json
  python scripts/export_roster.py --out path.json --compact

Required environment variables:
  SUPABASE_SERVICE_ROLE_KEY  -- same key scripts/competitor_scan.py uses.
Optional:
  SUPABASE_URL   -- defaults to the project URL hardcoded in zaher_crm.html (not a secret).
"""
import argparse
import json
import os
from datetime import datetime, timezone

import requests

SUPABASE_URL = os.environ.get('SUPABASE_URL', 'https://lzztbjjbtpuyatyxbrke.supabase.co').strip()
SERVICE_KEY = os.environ['SUPABASE_SERVICE_ROLE_KEY'].strip()
SB_HEADERS = {'apikey': SERVICE_KEY, 'Authorization': f'Bearer {SERVICE_KEY}'}

# Identity + the volatile scalars the weekly pass re-checks.
SCALARS = ['company', 'website', 'newsUrl', 'competitorType', 'deliveryModel', 'threatLevel',
           'sovereignModelCoverage', 'status', 'verified', 'executionScope', 'lastCheckedAt']
LISTS = ['dialects', 'platformsCovered', 'labels']
# Prose the researcher may overwrite — included in full so a delta can actually be computed.
PROSE = ['arabicDepthNotes', 'menaLocalizationNotes', 'proofNotes', 'reviewSources',
         'reviewSummary', 'arrEstimate', 'entryPrice', 'pricingModel', 'positioningClaim',
         'competitiveVerdict', 'featuresNotes', 'notes', 'radarEvidence']
# v2 radar. Kept in axis order so the file reads the same way the rubric does.
RADAR = ['radarArabicCitation', 'radarContentDepth', 'radarFeatureBreadth', 'radarTechnicalGeo',
         'radarAdoptionAccess', 'radarMarketAuthority', 'radarProvenOutcomes',
         'radarDialectCoverage', 'radarSovereignModels']


def sb_get(path, params=None):
    r = requests.get(f'{SUPABASE_URL}/rest/v1/{path}', headers=SB_HEADERS, params=params, timeout=30)
    r.raise_for_status()
    return r.json()


def days_since(iso):
    if not iso:
        return None
    try:
        d = datetime.fromisoformat(str(iso).replace('Z', '+00:00'))
        return (datetime.now(timezone.utc) - d).days
    except ValueError:
        return None


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument('--out', default='research/roster.json')
    ap.add_argument('--compact', action='store_true',
                    help='Omit prose fields. Smaller, but the research pass then cannot tell '
                         'whether a prose fact is already recorded — expect worse deltas.')
    args = ap.parse_args()

    competitors = sb_get('competitors', {'select': '*', 'order': 'company.asc'})
    signals = sb_get('competitor_signals',
                     {'select': 'competitor_id,type,description,occurred_on,confirmed',
                      'order': 'occurred_on.desc.nullslast', 'limit': '400'})
    by_comp = {}
    for s in signals:
        by_comp.setdefault(s['competitor_id'], []).append(s)

    out = []
    for c in competitors:
        row = {k: c.get(k) for k in SCALARS}
        row['staleDays'] = days_since(c.get('lastCheckedAt'))
        for k in LISTS:
            row[k] = c.get(k) or []
        if not args.compact:
            for k in PROSE:
                row[k] = c.get(k) or ''
        # Radar nulls stay null. 0 is a real score; None means not measured.
        row['radar'] = {k: c.get(k) for k in RADAR}
        # Three most recent signals, so the researcher doesn't re-report a known event.
        row['recentSignals'] = [
            {'type': s['type'], 'occurred_on': s.get('occurred_on'),
             'confirmed': s.get('confirmed'), 'description': (s.get('description') or '')[:220]}
            for s in by_comp.get(c['id'], [])[:3]
        ]
        out.append(row)

    doc = {
        'generatedAt': datetime.now(timezone.utc).isoformat(),
        'source': f'{SUPABASE_URL}/rest/v1/competitors',
        'competitorCount': len(out),
        'radarAxes': RADAR,
        'note': ('Current stored values for every competitor in the CRM. This IS the baseline for '
                 'the weekly research pass: write a cell only where today\'s verified fact differs '
                 'from what is here. null in radar means NOT MEASURED, never zero.'),
        'competitors': out,
    }

    os.makedirs(os.path.dirname(args.out) or '.', exist_ok=True)
    with open(args.out, 'w', encoding='utf-8') as f:
        json.dump(doc, f, ensure_ascii=False, indent=1)

    size = os.path.getsize(args.out)
    stale = [r['company'] for r in out if (r['staleDays'] or 999) > 14]
    print(f'Wrote {args.out}: {len(out)} competitors, {size/1024:.1f} KB')
    if stale:
        print(f'  not checked in >14 days ({len(stale)}): ' + ', '.join(stale[:12]))
    if size > 400_000:
        print('  WARNING: roster is large; consider --compact (see the docstring tradeoff)')


if __name__ == '__main__':
    main()
