#!/usr/bin/env python3
"""
Offline tests for scripts/apply_research_csv.py. No network, no credentials, no live DB.

Stubs the three Supabase calls and asserts on the resolved change set, so the parsing,
diffing, equality-skip and guard logic can be verified in CI or on a laptop without
touching production. Any write attempted during a dry run is a hard failure.

Run from the repo root:  python scripts/test_apply_research_csv.py
"""
import glob
import io
import csv
import os
import sys
import tempfile
import contextlib

os.environ.setdefault('SUPABASE_SERVICE_ROLE_KEY', 'test-key-not-real')
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import apply_research_csv as A  # noqa: E402

FAILURES = []


def check(label, cond, detail=''):
    print(f'  {"PASS" if cond else "FAIL"}  {label}{"" if cond else "  -- " + detail}')
    if not cond:
        FAILURES.append(label)


def no_writes(*a, **k):
    raise AssertionError('a write was attempted during a dry run')


def run(argv, fake_db):
    """Run main() with a stubbed DB, capturing stdout."""
    A.sb_get = lambda path, params=None: (fake_db if path == 'competitors' else [])
    A.sb_patch = no_writes
    A.sb_insert = no_writes
    buf = io.StringIO()
    sys.argv = ['apply_research_csv.py'] + argv
    try:
        with contextlib.redirect_stdout(buf):
            A.main()
    except SystemExit as e:
        return buf.getvalue(), str(e)
    return buf.getvalue(), None


def latest_csv():
    files = sorted(glob.glob('research/competitors/*.csv'))
    if not files:
        sys.exit('No CSV found in research/competitors/ — run from the repo root.')
    return files[-1]


def blank_row(company, **kw):
    row = {'id': abs(hash(company)) % 10000, 'company': company,
           'dialects': [], 'platformsCovered': [], 'labels': []}
    row.update(kw)
    return row


def main():
    csv_path = latest_csv()
    print(f'Testing against {csv_path}\n')

    # ---- 1. Delta semantics against a populated DB
    print('1. Delta semantics')
    db = [
        blank_row('ARGEO', threatLevel='Low', entryPrice='$450/mo retainer, $750 one-off audit',
                  notes='1-10 staff. No funding.', radarContentDepth=2, radarTechnicalGeo=3,
                  status='Operational', lastCheckedAt='2026-08-16T00:00:00+00:00'),
        blank_row('Peec AI', status='Operational', lastCheckedAt='2026-08-16T00:00:00+00:00'),
    ]
    out, exit_msg = run([csv_path, '--dry-run'], db)
    check('exits cleanly', exit_msg is None, str(exit_msg))
    check('nothing written on --dry-run', 'DRY RUN' in out)
    check('ARGEO threatLevel Low -> Medium', "threatLevel: 'Low' -> 'Medium'" in out)
    check('ARGEO radar 2 -> 4', 'radarContentDepth: 2 -> 4' in out)
    check('unknown companies become new rows', 'NEW ROWS (22)' in out,
          'expected every non-stubbed company to insert')
    # Peec AI's row is company + lastCheckedAt + status only, and status already matches,
    # so it must land in the touch-only bucket rather than being rewritten.
    check('unchanged row is touch-only', 'Peec AI' in out.split('TOUCHED, NO FIELD CHANGES')[1])

    # ---- 2. Equality skip (idempotency): re-applying the same file must be a near no-op
    print('\n2. Equality skip / idempotency')
    # Build the "already stored" state from the script's own parser, so the DB holds
    # exactly what the file says. A second pass over it must therefore change nothing.
    idx, data_rows = A.read_rows(csv_path)
    argeo_row = next(r for r in data_rows if r[idx['company']] == 'ARGEO')
    already = A.build_change_set(idx, argeo_row, lambda *a: None, 'ARGEO')
    already.update({'id': 1, 'company': 'ARGEO'})
    for f in ('dialects', 'platformsCovered', 'labels'):
        already.setdefault(f, [])

    out2, _ = run([csv_path, '--dry-run'], [already])
    argeo_block = out2.split('UPDATED ROWS')[1].split('TOUCHED')[0]
    check('re-apply does not rewrite identical values', 'ARGEO' not in argeo_block,
          'ARGEO still showed field changes on a second identical pass')
    check('re-apply still bumps lastCheckedAt', 'ARGEO' in out2.split('TOUCHED, NO FIELD CHANGES')[1])

    # ---- 3. Malformed cells are reported, never written
    print('\n3. Malformed cells')
    rows = list(csv.reader(open(csv_path, encoding='utf-8-sig')))
    hdr = rows[0]
    bad = [r[:] for r in rows[:2]]
    bad[1][hdr.index('company')] = 'ARGEO'
    bad[1][hdr.index('threatLevel')] = 'medium'            # wrong case
    bad[1][hdr.index('deliveryModel')] = 'Managed service'  # wrong case
    bad[1][hdr.index('radarContentDepth')] = 'high'         # non-numeric
    bad[1][hdr.index('radarSurfaceCoverage')] = '47'        # out of range -> clamps to 10
    bad[1][hdr.index('lastCheckedAt')] = 'sometime'         # unparseable
    # tempfile.gettempdir(), not a hardcoded '/tmp' -- this test also runs on a Windows laptop
    # (no /tmp there), not just the ubuntu-latest CI runner.
    tmp = os.path.join(tempfile.gettempdir(), '_bad_research.csv')
    with open(tmp, 'w', newline='', encoding='utf-8-sig') as f:
        csv.writer(f).writerows(bad)
    out3, _ = run([tmp, '--dry-run'], [blank_row('ARGEO', threatLevel='Low')])
    for field in ('threatLevel', 'deliveryModel', 'radarContentDepth', 'lastCheckedAt'):
        check(f'{field} rejected, not coerced', f'ARGEO.{field}' in out3)
    check('out-of-range radar clamps to 10', 'radarFeatureBreadth: (empty) -> 10' in out3)
    check('rejected enum did not reach the change set', "threatLevel: 'Low' ->" not in out3)

    # ---- 3b. v1 -> v2 back-compat: the old radarSurfaceCoverage header must land in
    # radarFeatureBreadth, so a historical v1 CSV still imports after the rename.
    print('\n3b. v1 header back-compat')
    idxbc, _ = A.read_rows(csv_path)
    hdr_l = [h.strip().lower() for h in open(csv_path, encoding='utf-8-sig').readline().split(',')]
    if 'radarsurfacecoverage' in hdr_l:
        check('v1 radarSurfaceCoverage header maps to radarFeatureBreadth',
              idxbc.get('radarFeatureBreadth') == hdr_l.index('radarsurfacecoverage'))
    else:
        check('v2 radarFeatureBreadth header recognised', 'radarFeatureBreadth' in idxbc)
    check('radarMarketAuthority is a known field', 'radarMarketAuthority' in A.FIELD_ALIASES)
    check('radarEvidence is treated as text, not a score',
          'radarEvidence' in A.STRING_FIELDS and 'radarEvidence' not in A.RADAR_FIELDS)
    check('retired axes still importable',
          'radarDialectCoverage' in A.RADAR_FIELDS and 'radarSovereignModels' in A.RADAR_FIELDS)

    # ---- 4. Overwrite guard
    print('\n4. Overwrite guard')
    packed = [blank_row(c, notes='stored', featuresNotes='stored', positioningClaim='stored',
                        entryPrice='stored', pricingModel='stored', arabicDepthNotes='stored',
                        menaLocalizationNotes='stored', proofNotes='stored', threatLevel='Low')
              for c in ('ARGEO', 'upGrowth', 'Dfeelings', 'Stand Out', 'Maps of Arabia',
                        'Scrunch', 'Magneto IT Solutions')]
    _, msg = run([csv_path, '--max-overwrites', '2'], packed)
    check('guard aborts before writing', msg is not None and 'ABORTED' in msg, str(msg))
    out5, msg5 = run([csv_path, '--max-overwrites', '500', '--dry-run'], packed)
    check('generous limit does not abort', msg5 is None)

    print()
    if FAILURES:
        sys.exit(f'{len(FAILURES)} test(s) failed: ' + ', '.join(FAILURES))
    print('All tests passed.')


if __name__ == '__main__':
    main()
