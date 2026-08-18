# Competitor research pipeline

Two automated jobs write to the `competitors` table. They do different work and must not be
confused:

| | `competitor-scan.yml` | `apply-research.yml` |
|---|---|---|
| Runs | Mondays 06:00 UTC + on-demand | On push to `research/**` + on-demand |
| Does | HTTP health-check each known URL, extract signals from news pages via Groq | Apply a researched delta CSV: pricing, funding, radar scores, new entrants |
| Can't do | Search beyond known URLs, verify pricing, find new competitors, re-score the radar | Discover anything — it only applies a file |
| Writes | `status`, `lastCheckedAt`, unconfirmed `competitor_signals` | Any competitor column, plus signals |

## How the weekly loop works

0. `competitor-scan.yml` (Mondays 06:00 UTC) health-checks every known site, queues signals, then
   regenerates `research/roster.json` from the current `competitors` table and commits it
   (`[skip ci]`, so this doesn't itself trigger `apply-research.yml`) — see `research/ROSTER.md`.
1. The Cowork scheduled research run (Mondays 08:00 UTC, two hours later) fetches `roster.json` as
   its baseline, researches, and produces `research/competitors/zaher-crm-competitors-YYYY-MM-DD.csv`
   and optionally `research/signals/YYYY-MM-DD.json`.
2. Those files get committed to `master`.
3. `apply-research.yml` fires, dry-runs (diff goes in the Actions log), then writes to Supabase.

Because every weekly delta is a commit, `git log research/competitors/` is a full audit trail
of what changed in the directory and when — and `git revert` undoes a bad week.

## The CSV format

40 columns (v2 radar spec — see below), UTF-8 with BOM, CRLF. The authoritative header order is
in `research/scheduled_task_prompt_v2.txt`. It is a **delta file**: a non-blank cell replaces the
stored value, a blank cell means "not researched this pass" and leaves the stored value alone.
You cannot clear a field through this file — a blank never erases.

Constrained columns are matched **case-sensitively** against the DB CHECK constraints. An
unrecognised value is reported and the field left untouched, never silently coerced:

- `competitorType`: `MENA/Regional` | `Generic/International`
- `deliveryModel`: `Self-serve SaaS` | `Managed Service` | `Consulting` | `Suite Add-on`
- `threatLevel`: `High` | `Medium` | `Low`
- `sovereignModelCoverage`: `Yes` | `No` | `Unverified`
- `status`: `Operational` | `Inactive` | `Unknown`
- `executionScope`: `Monitoring only` | `Monitoring + Execution`
- `verified`: `Yes` | `No`

List columns (`dialects`, `platformsCovered`, `labels`) are semicolon-separated. Writing a list
replaces the whole stored list. The nine radar columns (`radarArabicCitation`,
`radarContentDepth`, `radarFeatureBreadth`, `radarTechnicalGeo`, `radarAdoptionAccess`,
`radarMarketAuthority`, `radarProvenOutcomes`, plus the retired-from-the-chart-but-still-stored
`radarDialectCoverage`/`radarSovereignModels`) are integers 0–10; blank means unchanged, **not
zero**. `radarEvidence` is free text (per-axis provenance), not a score — never validated as a
number. `radarFeatureBreadth` (renamed from `radarSurfaceCoverage`) and `radarMarketAuthority`
are new in v2; see `migrations/competitors_radar_v2_migration.sql` for the schema change and
`research/scheduled_task_prompt_v2.txt` for what each axis measures. `relationship`,
`date_entered` and `date_modified` are ignored — the first is derived
by `competitorRelationship()`, the other two are display stamps.

## Running it by hand

```bash
export SUPABASE_SERVICE_ROLE_KEY=...            # never commit this

# Always preview first — prints a per-field diff and writes nothing
python scripts/apply_research_csv.py research/competitors/zaher-crm-competitors-2026-08-17.csv --dry-run

# Apply
python scripts/apply_research_csv.py research/competitors/zaher-crm-competitors-2026-08-17.csv \
  --signals research/signals/2026-08-17.json
```

Or from the Actions tab: **Apply competitor research → Run workflow**, with a `dry_run` toggle.

## Safety

The browser importer gates destructive writes behind a `confirm()`. Headless, that becomes
`--max-overwrites` (default 60): the script counts how many **populated, differing** fields the
file would replace on existing rows, and aborts before writing anything if the count is
exceeded. A normal weekly delta lands around 20; a file with a shifted header row or misaligned
columns blows straight past it and fails loudly instead of quietly flattening the directory.

Signals are inserted with `confirmed: false`, so they land in the same review queue the
scraper's signals do and a human still signs off before they count.

## Keeping the two importers in sync

`scripts/apply_research_csv.py` is a port of `handleCompetitorImportFile()` in `zaher_crm.html`.
Same format, same rules. If you change the rules in one, change them in the other. The
divergences are deliberate and documented at the top of the script:

1. **Equality skip** — a cell matching what's already stored is dropped from the PATCH, so the
   `competitor_score_history` trigger doesn't log phantom radar moves on every weekly run.
2. **`confirm()` → `--max-overwrites`** — no user to prompt.
3. **`--dry-run`** — prints the diff, writes nothing.
