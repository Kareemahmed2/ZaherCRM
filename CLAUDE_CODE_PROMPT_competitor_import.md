# Fix the competitor CSV/Excel importer in `zaher_crm.html`

## Context

`zaher_crm.html` is a single-file CRM (vanilla JS, Supabase via `sb`, SheetJS as `XLSX`, no build step). The Competitors tab is a flat monitoring directory backed by the `competitors` table — deliberately not part of the partners/customers/investors/events pipeline machinery.

A competitor CSV/Excel importer was recently added: `IMPORT_FIELD_MAP_COMPETITORS` (~line 3204), `mapCompetitorHeaders()` (~3231) and `handleCompetitorImportFile()` (~3242), wired to the Import button at line 648. It runs in **overwrite mode** — any non-blank cell replaces the stored value; a blank cell means "not researched this pass" and leaves the field alone. That design is correct and should be kept.

The file it has to consume is `zaher-crm-competitors-2026-08-16.csv`: 14 rows, 38 columns, produced to match `exportCompetitors()` (~3370) column-for-column, plus 8 radar score columns and `radarScoredAt`. Column headers are exact camelCase field names (`arabicDepthNotes`, `platformsCovered`, `radarContentDepth`, …). Cells contain multi-paragraph text with embedded newlines, `;`-separated lists, Arabic text, and currency symbols including `₹` and `€`.

Relevant DB constraints in `supabase_schema.sql`:

```sql
"competitorType"  check in ('MENA/Regional','Generic/International')   not null
"deliveryModel"   check in ('Self-serve SaaS','Managed Service','Consulting','Suite Add-on')
"threatLevel"     check in ('High','Medium','Low')
"sovereignModelCoverage" check in ('Yes','No','Unverified')  not null default 'No'
"executionScope"  check in ('Monitoring only','Monitoring + Execution')
status            check in ('Operational','Inactive','Unknown')  not null default 'Unknown'
company           text not null unique
```

Please work through the bugs below in severity order. Keep the existing code style (compact, comment the *why* not the *what*, no new dependencies, no build step). Do not refactor beyond what each fix needs.

---

## P0 — data loss and silent desync

### 1. Rows that fail a DB check constraint are shown as imported but never persist

`handleCompetitorImportFile()` validates only four of the six check-constrained columns. `deliveryModel` (line 3287, inside the `setStr` list) and `executionScope` (same list) are written as raw strings straight from the cell.

Any value off the allowed list — `"Managed service"` lowercase, `"Monitor only"`, `"Self-serve SaaS (claimed)"` — passes the importer, then fails the Postgres check on write. `createCompetitor()` (1493) and `saveCompetitor()` (1485) both catch the error, `console.error` it, toast `"Sync failed — …kept locally only"` and return `false`. The importer ignores both return values, so:

- line 3329 `competitors.push(c)` runs regardless of whether the insert succeeded
- the final toast still reports `"N new, M existing updated"`
- the grid re-renders showing the new data
- on next page load the rows are gone, or silently unchanged

**Fix:** validate `deliveryModel` and `executionScope` through `matchInList()` the same way `competitorType`/`threatLevel`/`sovereignModelCoverage`/`status` already are (3288–3295). Then track per-row persistence outcome and report it: `"12 imported, 2 failed to sync (see console)"`. Do not push a record into `competitors` when `createCompetitor()` returned `false`.

### 2. Unrecognised enum values are swallowed with no warning

`matchInList()` returns `null` on no match, and every call site treats `null` as "cell was blank". A row whose `threatLevel` says `Unverified` (not in the check constraint) or whose `status` says `Partially operational` imports "successfully" with that field silently unchanged — the user has no way to know a value was rejected.

**Fix:** distinguish "cell was blank" from "cell had a value we could not match". Collect the latter into a list and surface a count in the completion toast plus detail in `console.warn` — e.g. `"3 cells had unrecognised values and were skipped"`.

### 3. Overwrite mode has no undo and no confirmation

The comment at 3279 correctly notes there's no undo bar because `undoLastImport()`/`importUndoSnapshot()` are written against `records` + `TABLE_BY_PIPELINE`. But the mode has since changed from fill-blanks to **overwrite**, which makes that gap much sharper: importing an old export silently destroys every hand-edited `competitiveVerdict`, `notes` and `proofNotes` in the directory, irreversibly.

**Fix (pick the lightest that works):** before writing anything, if the file would modify existing rows, show a confirm dialog naming the count and a few affected companies — `"This will overwrite fields on 14 existing competitors. Continue?"`. Better if cheap: snapshot the affected records into a module-level `lastCompetitorImportUndo` and reuse the existing `.import-undo-bar` markup with a competitor-specific undo handler.

### 4. `saveCompetitor()` / `createCompetitor()` send the entire local object as the payload

Both do `const {id, ...payload} = c` and hand the whole thing to PostgREST. Any key on the local object that isn't a real column makes the request fail with `PGRST204` and takes the entire row's update with it.

This is currently latent but becomes live the moment fix #5 lands and the importer starts attaching radar fields before the migration has been run against that environment.

**Fix:** whitelist the columns before sending. One shared `const COMPETITOR_COLUMNS=[…]` used by both functions and by the importer.

---

## P1 — the file's data doesn't round-trip

### 5. All 9 radar columns are dropped on import

`IMPORT_FIELD_MAP_COMPETITORS` has no entry for `radarArabicCitation`, `radarContentDepth`, `radarDialectCoverage`, `radarSovereignModels`, `radarSurfaceCoverage`, `radarTechnicalGeo`, `radarAdoptionAccess`, `radarProvenOutcomes` or `radarScoredAt`, so `mapCompetitorHeaders()` never indexes them and the scores are discarded.

**Fix:** add all nine to the map. The eight scores are integers 0–10 — parse with `Number()`, reject `NaN`, clamp to 0–10, and round. Critically: **an empty score cell must store `null`, not `0`** — `radarArabicCitation` is empty for all 14 rows because it is not desk-researchable, and rendering that as a zero would misreport it as "scored zero on Arabic citations". `radarScoredAt` is a timestamp.

### 6. `lastCheckedAt` is never imported and never set

`exportCompetitors()` writes `lastCheckedAt` (line ~3378) but the import map has no entry for it, and new records are hardcoded `lastCheckedAt:null` (3318). So a CSV import — which is by definition a fresh research pass — leaves the "Last checked" column empty in the directory and `timeAgo()` renders nothing.

**Fix:** map `lastCheckedAt` (accept `"Aug 16, 2026"`, ISO, and Excel serial dates — guard with `isNaN(new Date(v))`). If a row provides no value, set `lastCheckedAt` to now on any row the import touched.

### 7. Export omits the radar columns, so export → edit → import loses them

`exportCompetitors()` (3370) predates the radar work and emits 29 columns. Once #5 lands, a user who exports, edits a price in Excel and re-imports will wipe all eight scores back to blank.

**Fix:** add the eight radar columns and `radarScoredAt` to the exported row object, positioned after `labels` and before `date_entered` to match the supplied CSV exactly.

### 8. `relationship` is exported but has no import path

`exportCompetitors()` emits `relationship` from `competitorRelationship(c)` (1567), which derives Direct/Indirect purely from `competitorType`. The import map aliases `'relationship type'` → `competitorType`, which is a different thing.

Two problems. The derivation itself is wrong for this dataset — it labels Magneto IT, Dfeelings, Stand Out and Maps of Arabia "Direct competitors" when they are agencies competing for budget, not product. And if a header ever normalises to `'relationship type'`, the value `"Direct"` gets fed to `matchInList(['MENA/Regional','Generic/International'], …)`, fails both the exact and substring passes, returns `null`, and for a *new* record silently defaults `competitorType` to `'MENA/Regional'`.

**Fix:** remove `'relationship type'` from the `competitorType` aliases. Then decide with the user whether `relationship` should become a real stored column rather than a derived one — do not change the schema without asking.

---

## P2 — robustness

### 9. `splitList` splits on comma as well as semicolon

Line 3273: `.split(/[;,]/)`. Both the CRM's own export and the supplied CSV join lists with `'; '`, so any list value legitimately containing a comma — a label like `"acquired, repackaged"`, a platform like `"Claude (custom prompts, API)"` — shatters into fragments.

**Fix:** split on `/[;|]/` only.

### 10. `matchInList()`'s substring fallback can silently assign a wrong enum

Line 1312: `list.find(s => s.toLowerCase().includes(n))`. Any short or partial cell value matches the first list entry containing it — a stray `"e"` in a status column resolves to `'Operational'`. It's shared with the pipeline importer, so don't change its behaviour globally.

**Fix:** in the competitor importer, require an exact (case-insensitive, trimmed) match, or add a minimum-length guard on the substring pass.

### 11. Sequential writes, no batching, toast storm on failure

Line 3329–3330 awaits `createCompetitor()` then `saveCompetitor()` once per row — 14 sequential round-trips for the supplied file, versus the single batched `insert(payloads)` the pipeline importer uses (~3176). Each failure also fires its own toast from inside `createCompetitor`/`saveCompetitor`, so a systematically bad file produces 14 stacked toasts.

**Fix:** batch the inserts into one `sb.from('competitors').insert(payloads).select()` and read the ids back in row order. Suppress the per-row toasts during import (pass a flag or a silent variant) and report once at the end.

### 12. `verified` silently becomes `false` for any unrecognised value

Line 3296 + `isTruthy` (3274) accepts `yes|true|1`. A cell containing `✓`, `y`, or `Verified` evaluates false and flips a verified competitor to unverified — an overwrite triggered by an unrecognised token rather than by intent.

**Fix:** widen the truthy set, add an explicit falsy set (`no|false|0`), and treat anything else as unrecognised — route it into the #2 warning path instead of defaulting to `false`.

---

## Also worth flagging (not importer bugs, but the CSV depends on them)

The radar is still on placeholders: `COMPETITOR_RADAR_METRICS` at line 3653 is `['Metric 1'…'Metric 8']` and `competitorRadarValues()` (3656) returns `20 + strHashIdx(...)` — deterministic noise, not data. Until that's swapped for the eight real axes reading the `radar*` fields, the grid at 3679 renders meaningless octagons and importing the scores changes nothing on screen. The axis labels, field names and 0–10→0–100 scaling are specified in `competitors_radar_migration.sql`.

---

## Testing

Use `zaher-crm-competitors-2026-08-16.csv`. It should exercise every path: 14 rows all matching existing companies by name, multi-paragraph cells with newlines, `;`-joined lists, Arabic text, `₹`/`€` symbols, one row (`Geoplex.ai`) with a deliberately blank `threatLevel`, and `radarArabicCitation` blank on all 14.

Verify after import:

1. All 14 rows report as synced; no `"kept locally only"` toast.
2. `select count(*) from competitors where "competitiveVerdict" like '%revised%'` returns > 0 — proves overwrite reached the seeded verdict text.
3. Threat ratings actually moved: Semrush and Peec AI → `High`, Maps of Arabia, Profound, Otterly and Scrunch → `Medium`, ARGEO and Dfeelings → `Low`.
4. `select count(*) from competitors where "radarArabicCitation" is null` returns 14, and no radar column contains a `0` that should have been `null`.
5. `lastCheckedAt` is populated on all 14.
6. Arabic text in `arabicDepthNotes` renders correctly, not mojibake — the file is UTF-8 with a BOM.
7. Export → re-import with no edits is a no-op: same 14 rows, no field changes, no new records.
8. A deliberately corrupted copy (`deliveryModel` set to `"Managed service"` lowercase on one row) reports that row as failed/unrecognised rather than appearing to succeed.
