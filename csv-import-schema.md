# ZaherCRM — CSV/Excel Import Schema Reference

Source: `zaher_crm.html` — `IMPORT_FIELD_MAP_COMMON`, `IMPORT_FIELD_MAP_EXTRA`, `mapHeaders()`, `handleImportFile()`.

## 1. How import targets a pipeline

There is **no pipeline column in the file**. Import always applies to whichever pipeline tab — **Partners**, **Customers**, or **Investors** — is currently active in the UI (`state.pipeline`) at the moment the user clicks Import. One file = one pipeline. If you have data for multiple pipelines, prepare separate files and import each while that pipeline's tab is open.

For **Partners** specifically, there's a further sub-split: Partners has two portfolios with different stage lists (`partners1` = the standard partner-progression stages, `partners2` = the "Ecosystem" stages). A `Portfolio` column (`1` or `2`) in the sheet picks the portfolio per-row; if omitted, new rows fall back to whichever portfolio tab is currently active in the UI.

## 2. Header matching rules

From `mapHeaders()`:

- Headers are matched **case-insensitively and trimmed** (`h.toString().trim().toLowerCase()`).
- A header matches a field if it equals one of that field's alias strings exactly (after normalization) — not a substring/fuzzy match.
- The alias table is the union of `IMPORT_FIELD_MAP_COMMON` (always active) plus whichever pipeline's block in `IMPORT_FIELD_MAP_EXTRA` applies.
- **Only `Company` (or `Name`) is required** in the header row. If neither is found, the import is rejected outright ("Could not find name/company columns in the header row"). Every other column is optional — omit anything you don't have data for.
- Column order doesn't matter; extra/unrecognized columns are simply ignored.

## 3. Recognized columns

### Common to all pipelines (`IMPORT_FIELD_MAP_COMMON`)

| Field | Accepted header aliases | What it maps to |
|---|---|---|
| `company` | `company`, `brand`, `organisation`, `organization` | The record's identity (the company/org). Required unless `name` is given instead. |
| `name` | `name`, `contact`, `contact name` | If different from the company name, becomes the row's contact person — the first/only entry in `members[]`. If it equals the company name (or is blank), no member is created from it alone. |
| `role` | `role`, `title` | Contact's job title → `member.title`. |
| `email` | `email` | Contact's email → `member.email`. Also used to match contacts across import batches (see §4). |
| `phone` | `phone` | Contact's phone → `member.phone`. |
| `linkedin` | `linkedin`, `linkedin url`, `linkedin profile` | Contact's LinkedIn URL → `member.linkedin`. |
| `stage` | `stage` | **New rows only** — fuzzy-matched (`matchInList`) against that pipeline's stage list; unmatched/blank defaults to the first stage. Never applied to existing companies (see §4d). |
| `value` | `value`, `mrr`, `arr`, `target`, `mrr/yr`, `mrr per year`, `potential arr`, `target raise` | Deal/record value (number). **New rows only** — never backfilled on an existing company. |
| `source` | `source` | Where the lead came from. Stored as `source` for Partners/Investors; for Customers it's folded into `leadSource` instead and the plain `source` field is deleted. New rows only. |
| `date` | `date` | Free-text date label. New rows only; defaults to `"Today"`. |
| `notes` | `notes` | Free text. The **only** company-level field that's backfilled on an existing record if it's currently blank — otherwise new-row only. |

A row only produces a contact/member if there's something to put in it: `hasContact` is true when `name` differs from `company`, or any of `email`/`phone`/`role`/`linkedin` is present. Otherwise no member row is created (company-only record).

### Partners-only (`IMPORT_FIELD_MAP_EXTRA.partners`)

| Field | Accepted header aliases | What it maps to |
|---|---|---|
| `portfolio` | `portfolio` | `1` or `2`, picks the stage-list/sub-pipeline for a **new** row; other values fall back to the active UI portfolio tab. |
| `category` | `category` | Fuzzy-matched against `CAT_META` keys (`Marketing Agencies`, `SaaS & E-commerce Platforms`, `Operational Touchpoint`, `Startup Development Orgs`, `Government & National Dev`); defaults to the first category if unmatched. |
| `model` | `model` | Free text (partnership model). |
| `tier` | `tier` | Number. |
| `score` | `score` | Number. |
| `website` | `website` | Free text URL. |
| `region` | `region` | Free text. |
| `clients` | `clients` | Free text. |
| `workshops` | `workshops` | Number — only stored when `portfolio===2`; defaults to `0` on new rows. |
| `founders` | `founders` | Number — only stored when `portfolio===2`; defaults to `0` on new rows. |

### Customers-only (`IMPORT_FIELD_MAP_EXTRA.customers`)

| Field | Accepted header aliases | What it maps to |
|---|---|---|
| `sector` | `sector` | Free text; **defaults to `"General"`** on brand-new companies only. |
| `website` | `website` | Free text URL. |
| `package` | `package` | Free text; defaults to `"—"` on new rows. |
| `aiScore` | `ai score`, `aiscore` | Number. |
| `leadSource` | `lead source`, `leadsource` | Free text; on new rows falls back to `source` if `leadSource` itself is blank, then to `"Import"`. |
| `referredBy` | `referred by`, `referredby` | Stored as a **number** (`Number(get('referredBy'))`) — i.e. an internal reference ID, not free text. New rows only — not in the existing-record backfill list, so re-importing never fills it in on an already-existing company. |
| `segment` | `segment`, `customer type` | Free text; **defaults to `"Enterprise"`** on brand-new companies only. |
| `nextStep` | `next step`, `nextstep` | Free text; defaults to the first configured next-step option (default list: `Send proposal`, `Schedule demo`, `Follow up call`, `Send contract`, `Onboarding kickoff`, `Check in`) if blank. |
| `subscriptionPeriod` | `subscription period`, `subscriptionperiod` | Only stored on new rows if `segment === 'Enterprise'`; otherwise stored as `''`. |
| `subscriptionDate` | `subscription date`, `subscriptiondate` | Only stored on new rows if `segment === 'SaaS'`; otherwise stored as `''`. |

### Investors-only (`IMPORT_FIELD_MAP_EXTRA.investors`)

| Field | Accepted header aliases | What it maps to |
|---|---|---|
| `fundSize` | `fund size`, `fundsize` | Free text. |
| `thesis` | `thesis` | Free text (investment thesis). |

## 4. What happens when a row's company already exists

A company is considered "existing" if it matches (case-insensitively, trimmed) a company already in the active pipeline in the database, **or** a company created earlier in the same import batch. In either case:

**(a) Never a duplicate company record.** No new top-level record is created — the row is folded into the existing one.

**(b) Contact/member matching — fill blanks only, never overwrite.**
A row's contact is matched to an existing member if `email` matches (case-insensitively) **OR** `name` matches (case-insensitively) — checking both, not just email-when-present, so a contact previously added without an email who later appears with one is recognized rather than duplicated.
- If matched: only fields on that member that are currently blank get filled — `email`, `phone`, `title`, `linkedin`. A populated field is never touched.
- If not matched: the new contact is appended as an additional member.

**(c) Company-level fields — same "fill blanks only" rule.** Filled only if the existing value is `null`/`''`/`undefined`, and the incoming value is non-empty/numeric:
- All pipelines: `notes`
- Partners: `category`, `model`, `tier`, `score`, `website`, `region`, `clients`, `workshops`, `founders`
- Customers: `sector`, `website`, `package`, `aiScore`, `leadSource`, `segment`, `nextStep`, `subscriptionPeriod`, `subscriptionDate`
- Investors: `fundSize`, `thesis`

Note that `name`, `role`, `email`, `phone`, `value`, `source`, `date`, and (for Customers) `referredBy` are **not** in these backfill lists — they only ever apply to brand-new rows, never to a merge.

**(d) `stage` is never touched on an existing company**, under any circumstance — this is deliberate. It's assumed a company already in the pipeline effectively always has a stage set, and a re-import must never roll back CRM progress that has moved forward since the spreadsheet was created.

If a matched row produces no member additions/fills and no field fills, it's counted as **skipped** (no new info) rather than merged.

## 5. What happens for a brand-new company row

A new record is created with sensible defaults for anything the sheet didn't supply:

- `stage`: fuzzy-matched against the pipeline's stage list, else the first stage in that list.
- `value`: `0` if blank/non-numeric.
- `source` (Partners/Investors): `"Import"` if blank.
- `date`: `"Today"` if blank.
- `notes`: `''` if blank.
- Partners: `category` defaults to the first `CAT_META` key; `model`/`website`/`region`/`clients` default to `''`; `tier`/`score` default to `null`; `workshops`/`founders` default to `0` (and are only stored at all when portfolio 2).
- Customers: `sector` defaults to **`"General"`**; `package` defaults to `"—"`; `aiScore`/`referredBy` default to `null`; `segment` defaults to **`"Enterprise"`**; `leadSource` falls back to `source` then `"Import"`; `nextStep` defaults to the first configured next-step option; `subscriptionPeriod`/`subscriptionDate` default to `''` and only one is populated depending on `segment`.
- Investors: `fundSize`/`thesis` default to `''`.
- `activity` gets a single `"Imported"` entry; `created_at`/`updated_at` are stamped with the import timestamp.
- Record `id` is never assigned client-side — it's a Postgres identity column, so new rows are inserted without an `id` and the server-assigned ids are read back afterward (this avoids two concurrent imports colliding on the same id).

## 6. Designing your spreadsheet — checklist

1. **Header row** — use the exact recognized names or any of their aliases (case doesn't matter). At minimum include `Company` (or `Name`).
2. **One row per contact, not per company** — if a company has multiple contacts, add multiple rows with the **same value in the Company column**; each row's `Name`/`Email`/`Phone`/`Role`/`LinkedIn` becomes a separate member on one merged record. This will not create duplicate companies.
3. **Company-level columns only need to appear once** for a given company (e.g. on its first row) — they'll be filled in when that row is processed; repeating them on every contact row for the same company is harmless (later blanks are simply no-ops) but not necessary.
4. **Leave cells blank** rather than guessing — blank cells are simply skipped, never coerce a wrong default.
5. **Do not include a `Stage` column expecting it to update existing companies** — it only ever applies to brand-new rows.
6. **Pick the correct pipeline tab before importing** — there is no way to route rows to different pipelines from within a single file.
7. **For Customers**, decide `Segment` per row (`Enterprise` vs `SaaS`) if you want `Subscription Period`/`Subscription Date` respected — only the matching one is stored.
8. **For Partners**, include a `Portfolio` column (`1` or `2`) per row if your rows span both partner sub-pipelines; otherwise make sure the correct portfolio sub-tab is active before importing.
9. Save as **.xlsx, .xls, or .csv** — all are read via `XLSX.read`, which auto-detects the format. **Every sheet in the workbook is scanned** (not just the first) — each sheet gets its own header row matched independently via `mapHeaders()`, so a workbook with one tab per vertical/category (no `Company`/`Name` header) is simply skipped for that tab, and companies repeated across sheets still merge into one record via the same cross-batch dedup as repeated rows within a single sheet.
10. Re-imports are safe: they only add missing members/fields and never overwrite existing values or move `stage` backward, so the same file (or an updated superset of it) can be imported repeatedly to progressively enrich records.
