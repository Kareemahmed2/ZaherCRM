#!/usr/bin/env python3
"""
Apply a weekly competitor-research CSV to Supabase, headlessly.

This is a server-side port of handleCompetitorImportFile() in zaher_crm.html. Same file
format, same OVERWRITE-with-blank-cell-skip semantics, same enum/radar/date validation --
but runs in GitHub Actions off a committed file instead of a browser file picker, so the
weekly Cowork research pass lands in the CRM with nobody clicking Import.

Why a port and not a reuse: the browser importer is coupled to the DOM (file input, toasts,
a confirm() gate) and to the in-memory `competitors` array. The *rules* are the valuable
part, so they're re-implemented here field-for-field. If you change the rules in one place,
change them in the other -- the divergences are deliberate and listed below.

DELIBERATE DIVERGENCES from the browser importer:
  1. Equality skip. A cell whose value already matches what's stored is dropped from the
     PATCH instead of being rewritten. The browser version rewrites unconditionally, which
     is harmless there. Here it would rewrite every unchanged radar value every week.
     competitor_score_history is NOT in the schema today (verified against
     supabase_schema.sql, 18 Aug 2026) but is planned; the moment it lands, blind
     rewrites would fill it with phantom radar "moves". Skipping equal values also
     keeps updated_at meaningful. lastCheckedAt is exempt -- re-writing it is the
     whole point of an unchanged row.
  2. confirm() -> --max-overwrites. There's no user to prompt, so the destructive-write gate
     becomes a numeric guard: abort if the file would replace more than N *populated,
     differing* fields on existing rows. A well-formed weekly delta lands well under the
     default; a malformed one (wrong header row, shifted columns) blows past it and aborts
     before writing anything.
  3. --dry-run prints the full per-field diff and writes nothing. Run it first, always.

Reads .csv only (UTF-8, BOM tolerated). The browser importer also accepts .xlsx via SheetJS;
adding that here would mean a new dependency for no gain, since the research pass emits CSV.

Usage:
  python scripts/apply_research_csv.py research/competitors/zaher-crm-competitors-2026-08-17.csv --dry-run
  python scripts/apply_research_csv.py research/competitors/zaher-crm-competitors-2026-08-17.csv
  python scripts/apply_research_csv.py <csv> --signals research/signals/2026-08-17.json

Required environment variables:
  SUPABASE_SERVICE_ROLE_KEY  -- bypasses RLS; same key scripts/competitor_scan.py uses.
                                NEVER commit this -- set as a GitHub Actions secret.
Optional:
  SUPABASE_URL   -- defaults to the project URL hardcoded in zaher_crm.html (not a secret).
"""
import argparse
import csv
import json
import math
import os
import re
import sys
from datetime import datetime, timezone

import requests

SUPABASE_URL = os.environ.get('SUPABASE_URL', 'https://lzztbjjbtpuyatyxbrke.supabase.co').strip()
SERVICE_KEY = os.environ['SUPABASE_SERVICE_ROLE_KEY'].strip()

SB_HEADERS = {
    'apikey': SERVICE_KEY,
    'Authorization': f'Bearer {SERVICE_KEY}',
    'Content-Type': 'application/json',
}

# ---------------------------------------------------------------- field mapping
# Mirrors IMPORT_FIELD_MAP_COMPETITORS in zaher_crm.html. Keep in sync.
FIELD_ALIASES = {
    'company': ['company', 'name', 'competitor', 'competitor name'],
    'website': ['website', 'url'],
    'competitorType': ['type', 'competitor type', 'competitortype'],
    'deliveryModel': ['delivery model', 'deliverymodel', 'delivery'],
    'threatLevel': ['threat', 'threat level', 'threatlevel'],
    'sovereignModelCoverage': ['sovereign', 'sovereign coverage', 'sovereign model coverage',
                               'sovereignmodelcoverage', 'jais/falcon'],
    'status': ['status'],
    'verified': ['verified'],
    'newsUrl': ['news url', 'newsurl', 'news/press page', 'press page'],
    'arabicDepthNotes': ['arabic depth notes', 'arabicdepthnotes', 'arabic depth', 'dialect notes'],
    'menaLocalizationNotes': ['mena localization notes', 'menalocalizationnotes', 'mena notes',
                              'localization notes'],
    'executionScope': ['execution scope', 'executionscope', 'execution'],
    'proofNotes': ['proof notes', 'proofnotes', 'proof of execution/monitoring', 'proof'],
    'reviewSources': ['review sources', 'reviewsources'],
    'reviewSummary': ['review summary', 'reviewsummary'],
    'arrEstimate': ['arr estimate', 'arrestimate', 'arr'],
    'entryPrice': ['entry price', 'entryprice'],
    'pricingModel': ['pricing model', 'pricingmodel', 'pricing'],
    'positioningClaim': ['positioning claim', 'positioningclaim', 'positioning'],
    'competitiveVerdict': ['verdict vs zaher ai', 'competitiveverdict', 'competitive verdict', 'verdict'],
    'featuresNotes': ['features notes', 'featuresnotes', 'features'],
    'notes': ['notes'],
    'dialects': ['dialects'],
    'platformsCovered': ['platforms covered', 'platformscovered', 'platforms'],
    'labels': ['labels', 'label'],
    'lastCheckedAt': ['last checked', 'lastcheckedat', 'last checked at'],
    'radarArabicCitation': ['radararabiccitation', 'radar arabic citation'],
    'radarContentDepth': ['radarcontentdepth', 'radar content depth'],
    # v2: radarSurfaceCoverage was renamed radarFeatureBreadth and redefined broader. The old
    # header stays as an alias so a v1 CSV still imports — the values carry over as provisional.
    'radarFeatureBreadth': ['radarfeaturebreadth', 'radar feature breadth', 'feature breadth',
                            'radarsurfacecoverage', 'radar surface coverage'],
    'radarTechnicalGeo': ['radartechnicalgeo', 'radar technical geo'],
    'radarAdoptionAccess': ['radaradoptionaccess', 'radar adoption access'],
    'radarMarketAuthority': ['radarmarketauthority', 'radar market authority', 'market authority'],
    'radarProvenOutcomes': ['radarprovenoutcomes', 'radar proven outcomes'],
    # Retired from the radar in v2 but still tracked as CRM data — sovereign-model coverage is
    # the highest-value thing the weekly scan watches for, so the column outlives the axis.
    'radarDialectCoverage': ['radardialectcoverage', 'radar dialect coverage'],
    'radarSovereignModels': ['radarsovereignmodels', 'radar sovereign models'],
    # Free text, not a score: compact per-axis provenance, e.g. '1:IND live basket; 2:ART sitemap'.
    'radarEvidence': ['radarevidence', 'radar evidence', 'evidence'],
    'radarScoredAt': ['radarscoredat', 'radar scored at'],
}

# Mirrors COMPETITOR_ENUM_VALUES -- these are Postgres CHECK constraints. Exact, case-sensitive.
ENUM_VALUES = {
    'competitorType': ['MENA/Regional', 'Generic/International'],
    'deliveryModel': ['Self-serve SaaS', 'Managed Service', 'Consulting', 'Suite Add-on'],
    'threatLevel': ['High', 'Medium', 'Low'],
    'sovereignModelCoverage': ['Yes', 'No', 'Unverified'],
    'executionScope': ['Monitoring only', 'Monitoring + Execution'],
    'status': ['Operational', 'Inactive', 'Unknown'],
}
STRING_FIELDS = ['website', 'newsUrl', 'arabicDepthNotes', 'menaLocalizationNotes', 'proofNotes',
                 'reviewSources', 'reviewSummary', 'arrEstimate', 'entryPrice', 'pricingModel',
                 'positioningClaim', 'competitiveVerdict', 'featuresNotes', 'notes', 'radarEvidence']
ENUM_FIELDS = list(ENUM_VALUES)
# v2 radar: axes 1-7 in order, then the two axes retired from the chart but still stored.
RADAR_FIELDS = ['radarArabicCitation', 'radarContentDepth', 'radarFeatureBreadth',
                'radarTechnicalGeo', 'radarAdoptionAccess', 'radarMarketAuthority',
                'radarProvenOutcomes', 'radarDialectCoverage', 'radarSovereignModels']
LIST_FIELDS = ['dialects', 'platformsCovered', 'labels']
DATE_FIELDS = ['lastCheckedAt', 'radarScoredAt']
# Mirrors COMPETITOR_COLUMNS -- anything outside this never reaches the DB. Columns present in
# the CSV but absent here (relationship, date_entered, date_modified) are ignored by design:
# `relationship` is derived by competitorRelationship(), the other two are display stamps.
DB_COLUMNS = set(STRING_FIELDS + ENUM_FIELDS + RADAR_FIELDS + LIST_FIELDS + DATE_FIELDS +
                 ['company', 'verified', 'created_at', 'updated_at'])

SIGNAL_TYPES = {'Funding', 'M&A', 'Product', 'Management Change', 'News'}


# ---------------------------------------------------------------- cell parsing
def is_placeholder(raw):
    """Mirrors isPlaceholderText(): blank, dashes, or n/a all read as 'not researched'."""
    s = ('' if raw is None else str(raw)).strip()
    return (not s) or bool(re.fullmatch(r'[-—]+', s)) or bool(re.fullmatch(r'n/?a', s, re.I))


def match_enum(field, raw):
    """undefined -> None (blank, leave alone); unrecognised -> UNRECOGNISED; else exact value."""
    if raw is None:
        return None
    s = str(raw).strip()
    return s if s in ENUM_VALUES[field] else UNRECOGNISED


def match_bool(raw):
    if raw is None:
        return None
    s = str(raw).strip().lower()
    if s in ('yes', 'true', '1', 'y', '✓', 'verified'):
        return True
    if s in ('no', 'false', '0', 'n', '✗', 'unverified'):
        return False
    return UNRECOGNISED


def parse_radar(raw):
    """0-10 integer. Never coerce a bad value to 0 -- 0 is a real score on several axes.
    Mirrors parseRadarScore()'s Math.round(n), not Python's round() -- Python 3's round()
    is banker's rounding (round-half-to-even: round(6.5) == 6), while JS Math.round() always
    rounds half up (Math.round(6.5) === 7). A researcher-entered "6.5" would clamp to a
    different integer depending on which importer ran, so floor(n + 0.5) reproduces the JS
    behaviour exactly for the non-negative range these scores live in."""
    if raw is None:
        return None
    try:
        n = float(str(raw).strip())
    except ValueError:
        return UNRECOGNISED
    return max(0, min(10, math.floor(n + 0.5)))


# JS `new Date("Aug 17, 2026")` in a UTC runner yields 2026-08-17T00:00:00.000Z. Match that,
# and accept ISO too so a re-exported file (which carries ISO timestamps) round-trips.
DATE_FORMATS = ['%b %d, %Y', '%B %d, %Y', '%Y-%m-%d', '%d %b %Y', '%d/%m/%Y']


def parse_date(raw):
    if raw is None:
        return None
    s = str(raw).strip()
    for fmt in DATE_FORMATS:
        try:
            return datetime.strptime(s, fmt).replace(tzinfo=timezone.utc).isoformat()
        except ValueError:
            pass
    try:
        return datetime.fromisoformat(s.replace('Z', '+00:00')).astimezone(timezone.utc).isoformat()
    except ValueError:
        return UNRECOGNISED


def split_list(raw):
    """Splits on ';' or '|' only -- a comma legitimately appears inside one list item."""
    if raw is None:
        return []
    return [p.strip() for p in re.split(r'[;|]', str(raw)) if p.strip()]


class _Unrecognised:
    def __repr__(self):
        return '<unrecognised>'


UNRECOGNISED = _Unrecognised()


# ---------------------------------------------------------------- supabase
def sb_get(path, params=None):
    r = requests.get(f'{SUPABASE_URL}/rest/v1/{path}', headers=SB_HEADERS, params=params, timeout=30)
    r.raise_for_status()
    return r.json()


def sb_patch(path, payload):
    r = requests.patch(f'{SUPABASE_URL}/rest/v1/{path}', headers={**SB_HEADERS, 'Prefer': 'return=minimal'},
                       json=payload, timeout=30)
    r.raise_for_status()


def sb_insert(path, payload):
    r = requests.post(f'{SUPABASE_URL}/rest/v1/{path}', headers={**SB_HEADERS, 'Prefer': 'return=representation'},
                      json=payload, timeout=30)
    r.raise_for_status()
    return r.json()


# ---------------------------------------------------------------- core
def read_rows(path):
    with open(path, newline='', encoding='utf-8-sig') as f:
        rows = list(csv.reader(f))
    if len(rows) < 2:
        sys.exit(f'ERROR: {path} has no data rows')
    header = [(h or '').strip().lower() for h in rows[0]]
    idx = {}
    for field, aliases in FIELD_ALIASES.items():
        for i, h in enumerate(header):
            if h in aliases:
                idx[field] = i
    if 'company' not in idx:
        sys.exit(f'ERROR: could not find a Company column in the header row of {path}')
    return idx, rows[1:]


def build_change_set(idx, row, warn, company):
    """Returns {db_field: value} for every non-blank, recognised cell in this row."""
    def get(field):
        i = idx.get(field)
        if i is None or i >= len(row):
            return None
        v = row[i]
        return None if is_placeholder(v) else v

    changes = {}
    for f in STRING_FIELDS:
        v = get(f)
        if v is not None and str(v).strip():
            changes[f] = str(v)
    for f in ENUM_FIELDS:
        m = match_enum(f, get(f))
        if m is UNRECOGNISED:
            warn(company, f, get(f))
        elif m is not None:
            changes[f] = m
    vb = match_bool(get('verified'))
    if vb is UNRECOGNISED:
        warn(company, 'verified', get('verified'))
    elif vb is not None:
        changes['verified'] = vb
    for f in LIST_FIELDS:
        lst = split_list(get(f))
        if lst:
            changes[f] = lst
    for f in RADAR_FIELDS:
        raw = get(f)
        if raw is None:
            continue
        v = parse_radar(raw)
        if v is UNRECOGNISED:
            warn(company, f, raw)
        else:
            changes[f] = v
    for f in DATE_FIELDS:
        raw = get(f)
        if raw is None:
            continue
        d = parse_date(raw)
        if d is UNRECOGNISED:
            warn(company, f, raw)
        else:
            changes[f] = d
    return {k: v for k, v in changes.items() if k in DB_COLUMNS}


def same_value(stored, incoming):
    """Equality check that tolerates the shapes Postgres hands back vs what we send.
    dialects / platformsCovered / labels are jsonb (not text[]), so PostgREST returns
    them as JSON arrays and a plain list in the payload round-trips correctly."""
    if isinstance(incoming, list):
        return [str(x) for x in (stored or [])] == [str(x) for x in incoming]
    if isinstance(incoming, bool) or isinstance(incoming, int):
        return stored == incoming
    if stored is None:
        return False
    # timestamps: compare as instants, not strings
    if isinstance(incoming, str) and re.match(r'^\d{4}-\d{2}-\d{2}T', incoming):
        try:
            a = datetime.fromisoformat(str(stored).replace('Z', '+00:00'))
            b = datetime.fromisoformat(incoming.replace('Z', '+00:00'))
            return a == b
        except ValueError:
            pass
    return str(stored).strip() == str(incoming).strip()


# Mirrors the `c = {...}` object literal in handleCompetitorImportFile()'s new-row branch,
# which sets every one of COMPETITOR_STRING_FIELDS to '' (via `(get(f)||'').toString()`) even
# when the CSV cell was blank -- a brand-new row never leaves a string column absent the way an
# *update* to an existing row does. Without this, a new-row INSERT here would simply omit those
# keys and Postgres would store NULL instead of '', diverging from what the browser importer
# would have written for the same file.
NEW_ROW_DEFAULTS = {
    'competitorType': 'MENA/Regional',
    'sovereignModelCoverage': 'No',
    'status': 'Unknown',
    'verified': False,
    **{f: '' for f in STRING_FIELDS},
}


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('csv_path')
    ap.add_argument('--signals', help='Optional JSON file of competitor signals to insert')
    ap.add_argument('--dry-run', action='store_true', help='Print the diff and write nothing')
    ap.add_argument('--max-overwrites', type=int, default=60,
                    help='Abort before writing if the file would replace more than this many '
                         'populated, differing fields on existing rows (default 60)')
    # supabase_schema.sql pins this:
    #   "detectedBy" text not null default 'manual' check ("detectedBy" in ('manual','scraper'))
    # 'research' would be rejected by the DB, so the choice is only between these two.
    # 'scraper' is right: these rows are machine-generated and land unconfirmed for review,
    # exactly like competitor_scan.py's. Widening the CHECK is a schema change, not a flag.
    ap.add_argument('--detected-by', default='scraper', choices=['scraper', 'manual'],
                    help="detectedBy for inserted signals. The DB CHECK allows only "
                         "'manual' or 'scraper'; default 'scraper' marks these as machine-"
                         "generated and pending review.")
    args = ap.parse_args()

    idx, rows = read_rows(args.csv_path)
    existing = sb_get('competitors', {'select': '*'})
    by_name = {(c.get('company') or '').strip().lower(): c for c in existing}
    print(f'Loaded {len(existing)} competitor(s) from Supabase; {len(rows)} row(s) in {args.csv_path}\n')

    unrecognised = []

    def warn(company, field, raw):
        unrecognised.append((company, field, raw))

    updates, inserts, noops = [], [], []
    overwrite_count = 0
    seen = set()

    for row in rows:
        if not row:
            continue
        ci = idx['company']
        company = (row[ci] if ci < len(row) else '').strip()
        if not company:
            continue
        key = company.lower()
        if key in seen:
            print(f'  ! duplicate row for "{company}" in this file -- later row wins')
        seen.add(key)

        changes = build_change_set(idx, row, warn, company)
        target = by_name.get(key)

        if target is None:
            payload = {**NEW_ROW_DEFAULTS, **changes, 'company': company}
            payload.setdefault('lastCheckedAt', datetime.now(timezone.utc).isoformat())
            for f in LIST_FIELDS:
                payload.setdefault(f, [])
            inserts.append((company, payload))
            continue

        # Equality skip -- see DELIBERATE DIVERGENCES #1. lastCheckedAt is exempt.
        applied, diff = {}, []
        for f, v in changes.items():
            if f == 'lastCheckedAt':
                applied[f] = v
                continue
            stored = target.get(f)
            if same_value(stored, v):
                continue
            applied[f] = v
            was = '(empty)' if stored in (None, '', []) else repr(stored)[:70]
            diff.append(f'      {f}: {was} -> {repr(v)[:70]}')
            if stored not in (None, '', []):
                overwrite_count += 1

        if not applied or (list(applied) == ['lastCheckedAt'] and not diff):
            # Re-checked, nothing changed: still bump lastCheckedAt so "Last checked" stays honest.
            if 'lastCheckedAt' in applied:
                updates.append((company, target['id'], {'lastCheckedAt': applied['lastCheckedAt']}, []))
            else:
                noops.append(company)
            continue
        updates.append((company, target['id'], applied, diff))

    # ---- report
    print('=' * 72)
    print(f'NEW ROWS ({len(inserts)})')
    for company, payload in inserts:
        print(f'  + {company}  [{len(payload)} fields]')
    print(f'\nUPDATED ROWS ({len([u for u in updates if u[3]])})')
    for company, _id, applied, diff in updates:
        if diff:
            print(f'  ~ {company}')
            for line in diff:
                print(line)
    touch_only = [u[0] for u in updates if not u[3]]
    print(f'\nTOUCHED, NO FIELD CHANGES ({len(touch_only)}) -- lastCheckedAt bump only')
    print('  ' + ', '.join(touch_only) if touch_only else '  (none)')
    if noops:
        print(f'\nSKIPPED, NOTHING TO WRITE ({len(noops)}): ' + ', '.join(noops))
    if unrecognised:
        print(f'\nUNRECOGNISED CELLS ({len(unrecognised)}) -- these fields were left untouched:')
        for company, field, raw in unrecognised:
            print(f'  ! {company}.{field} = {raw!r}')
    print(f'\nPopulated fields that would be overwritten: {overwrite_count} (limit {args.max_overwrites})')
    print('=' * 72)

    if overwrite_count > args.max_overwrites:
        sys.exit(f'\nABORTED: {overwrite_count} overwrites exceeds --max-overwrites={args.max_overwrites}. '
                 'Nothing was written. Check the file for a shifted header row or misaligned columns, '
                 'then re-run with a higher limit if the diff above is genuinely correct.')

    if args.dry_run:
        print('\nDRY RUN -- nothing written.')
        return

    # ---- write
    now = datetime.now(timezone.utc).isoformat()
    inserted_ids = {}
    for company, payload in inserts:
        payload['created_at'] = payload['updated_at'] = now
        try:
            data = sb_insert('competitors', payload)
            inserted_ids[company.lower()] = data[0]['id']
            print(f'  + inserted {company} (id {data[0]["id"]})')
        except requests.HTTPError as e:
            print(f'  ! INSERT FAILED for {company}: {e.response.status_code} {e.response.text[:200]}')
    for company, cid, applied, _diff in updates:
        applied['updated_at'] = now
        try:
            sb_patch(f'competitors?id=eq.{cid}', applied)
            print(f'  ~ updated {company} ({len(applied) - 1} field(s))')
        except requests.HTTPError as e:
            print(f'  ! UPDATE FAILED for {company}: {e.response.status_code} {e.response.text[:200]}')

    if args.signals:
        apply_signals(args.signals, by_name, inserted_ids, args.detected_by)

    print('\nDone.')


def apply_signals(path, by_name, inserted_ids, detected_by):
    """Insert research signals, deduped against what's already stored for that competitor.
    Dedup mirrors is_duplicate() in competitor_scan.py so the two sources don't fight."""
    with open(path, encoding='utf-8') as f:
        signals = json.load(f)
    print(f'\nApplying {len(signals)} signal(s) from {path}')
    for s in signals:
        company = (s.get('company') or '').strip()
        key = company.lower()
        cid = inserted_ids.get(key) or (by_name.get(key) or {}).get('id')
        if not cid:
            print(f'  ! no competitor matched "{company}" -- signal skipped')
            continue
        if s.get('type') not in SIGNAL_TYPES:
            print(f'  ! bad signal type {s.get("type")!r} for {company} -- skipped')
            continue
        desc = (s.get('description') or '').strip()
        if not desc:
            print(f'  ! empty description for {company} -- skipped')
            continue
        stored = sb_get('competitor_signals', {'select': 'type,description', 'competitor_id': f'eq.{cid}'})
        cand = desc.lower()
        dup = any(e.get('type') == s['type'] and
                  ((e.get('description') or '').strip().lower() == cand or
                   (len(cand) > 20 and cand[:20] in (e.get('description') or '').lower()))
                  for e in stored)
        if dup:
            print(f'  = {company}: already have this {s["type"]} signal -- skipped')
            continue
        try:
            sb_insert('competitor_signals', {
                'competitor_id': cid,
                'type': s['type'],
                'description': desc[:500],
                'source_url': s.get('source_url') or '',
                'occurred_on': s.get('occurred_on') or None,
                'detectedBy': detected_by,
                # Left unconfirmed on purpose: these land in the same review queue the
                # scraper's signals do, so a human still signs off before they count.
                'confirmed': False,
            })
            print(f'  + {company}: {s["type"]} -- {desc[:60]}')
        except requests.HTTPError as e:
            print(f'  ! SIGNAL INSERT FAILED for {company}: {e.response.status_code} {e.response.text[:200]}')


if __name__ == '__main__':
    main()
