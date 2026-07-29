# Customers: company-based identity, members list, subscription fields

## Context

Customers currently model a single person as "the client" (`name`/`role`/`email`/`phone` on the record itself), with `company` as a secondary field. The user wants customers to be **company-based**: the company name is the primary identity, and the people at that company become a **members list** (name, email, phone, title, linkedin) that can grow over time via a button, rather than one hardcoded contact. Alongside this, Enterprise customers need a `subscriptionPeriod` and SaaS customers need a `subscriptionDate`.

This only applies to the `customers` entity — partners and investors keep their existing single-contact model untouched. The `customers` table already holds real production data (confirmed in the prior table-split work), so existing rows must be migrated, not dropped.

**Decisions already confirmed with the user:**
- `subscriptionPeriod` is free text (not a fixed dropdown).
- Existing customer contact data (`name`/`role`/`email`/`phone`) auto-migrates into the new `members` list as each customer's first member.
- Where a single contact name used to show (kanban card, directory row), show the first member's name + title instead, with company as the primary line.

## Approach

### 1. Supabase (`supabase_schema.sql`)
- `alter table customers add column if not exists "subscriptionPeriod" text;`
- `alter table customers add column if not exists "subscriptionDate" text;`
- `alter table customers add column if not exists members jsonb not null default '[]'::jsonb;`
- One-time migration (safe to re-run, guarded by `jsonb_array_length`):
  1. For rows where `members` is empty and the existing `name` differs from `company`, build a single-member array from the current `name`/`email`/`phone`/`role` (`role` → `title`, `linkedin` → `''`).
  2. Then normalize every customer row: `name = company`, and blank `role`/`email`/`phone` at the top level (that data now lives in `members`; the columns stay in the schema since they're shared with partners/investors, just unused for customers going forward).

### 2. Data-layer helpers (`zaher_crm.html`)
- `findRecord(q)`: add a fallback pass matching `q` against `(r.members||[]).some(m=>m.name...)` (exact, then partial) so chat/UI lookups by a contact's name still resolve to the right customer — this is a real regression risk since `r.name` no longer holds a person's name for customers.
- New small helpers: `customerPrimaryMember(r)` → `(r.members||[])[0] || null`, used everywhere a "contact" used to be shown for customers.
- Directory search filter (`renderDirectory`, ~line 969) gains an `.some(m=>...)` clause over `members` (name + email) so searching still finds a customer by a person's name/email.

### 3. Rendering (dashboard recent table, kanban card, directory rows, detail header)
- These currently show `r.name` as the bold primary line and `r.company` as secondary, generically across all three pipelines. For `pipeline==='customers'` specifically, flip it: primary = `r.company`, secondary = primary member's `name · title` (or an em dash if no members yet). Partners/investors branches are untouched.
- Avatar initials (`ini(...)`) switch from `r.name||r.company` to `r.company` for customers in these same spots.
- Detail page (`renderDetail`): `det-role` (the line under the profile name) shows the primary member's name/title for customers instead of `company · role`. `det-contact-btn`'s "Email" action uses the primary member's email for customers. The generic top fields (`Email`/`Phone`/`Company`) are dropped for the customers branch specifically (company's already the header; multiple emails/phones now live in Members) and replaced with the existing sector/segment/package/aiScore/value/leadSource fields plus the new conditional field: `Subscription period` if `segment==='Enterprise'`, `Subscription date` if `segment==='SaaS'`.

### 4. Members UI (new, additive)
- New card on the customer detail page (mirrors the existing `det-score-card` show/hide-by-pipeline pattern): a "Members" card listing each member (name, title, email as mailto link, phone, LinkedIn link) with a **+ Add Member** button in its header.
- New lightweight modal `#member-modal`, cloned from the existing `#scorer` modal pattern (`.modal-overlay`/`.modal`/`.modal-header`/`.modal-body` with `.form-group`/`.form-row`/`.form-input`, `.modal-footer`) — fields: name*, title, email, phone, linkedin. Submit pushes into `r.members`, calls `saveRecord(r)`, logs an activity entry, closes the modal, re-renders.
- No delete/edit-member UI in this pass (matches the user's ask: a button to add members; not asked for edit/remove) — easy to add later if wanted.

### 5. Add/Edit customer form (`extraFieldsHtml`, `renderModalForm`, `addRecord`, `saveEditedRecord`)
- `renderModalForm`'s generic "Contact name" / "Role" / "Email" / "Phone" rows (currently shown for every pipeline) are skipped for `p==='customers'` — that data now lives in Members, managed separately from this modal.
- `extraFieldsHtml`'s customers branch gains the conditional Subscription field: one `form-group` for period, one for date, toggled by the existing Segment `<select>`'s `onchange` (new `toggleSubscriptionFields(val)` helper flips two `style.display`s) so only the relevant one shows.
- `addRecord()`/`saveEditedRecord()`: for `p==='customers'`, set `r.name = company` directly (no `f-name`/`f-role`/`f-email`/`f-phone` reads), preserve `r.members` as-is on edit (default `[]` on add), and read `f-subperiod`/`f-subdate` into `subscriptionPeriod`/`subscriptionDate` based on the chosen segment.

### 6. CSV/Excel import & export
- `IMPORT_FIELD_MAP_EXTRA.customers` gains `subscriptionPeriod`/`subscriptionDate` aliases.
- In `handleImportFile`'s customers branch: if the row has a `name`/`email`/`phone`/`role` value, build it into a single-entry `members` array (same shape as the DB migration) instead of discarding it, then set `r.name=company` and clear the top-level `role`/`email`/`phone` — mirrors the production migration logic exactly, so imported data isn't silently dropped.
- `exportRecords()`: add `subscriptionPeriod`, `subscriptionDate` columns, and a flattened `members` column (e.g. `"Sara Rashid (Head of Marketing) <sara@noon.com>; ..."`) — read-only summary, not intended for structured re-import (members import intentionally stays out of scope for tabular CSV, consistent with not over-building this).

### 7. Chatbot (`buildSystem`, `snapshot`, `TOOLS`, `execTool`)
- `snapshot()`: for customers, drop the now-redundant `contact:r.name` (would just equal company) and add `members: r.members.map(m=>({name,title}))` plus whichever of `subscriptionPeriod`/`subscriptionDate` applies to that row's segment.
- `buildSystem()`'s customers description gets one added sentence: customers are company-based with a `members` list instead of a single contact, and track a subscription period (Enterprise) or subscription date (SaaS).
- `add_record`'s customers branch: force `r.name = input.company` (ignore any contact-name-shaped input), set `r.members=[]`, and read new optional `subscriptionPeriod`/`subscriptionDate` inputs (added to the `add_record` tool's JSON schema) based on the resolved segment.
- Adding members *through the chatbot* (a new `add_member` tool) is out of scope for this pass — the user asked for a UI button specifically; can be added later as a natural follow-on.

### 8. Seed data (`SEED_RECORDS`)
- Update the 7 existing customer seed rows: set `name` = `company`, add a `members` array (migrating their current `name`/`role`/`email`/`phone` into it), and add `subscriptionPeriod` (Enterprise rows) or `subscriptionDate` (SaaS rows) with plausible sample values — keeps the no-Supabase / seed-fallback path consistent with the new shape.

## Files touched
- `supabase_schema.sql` (3 new columns + migration on `customers`)
- `zaher_crm.html`: `findRecord`, `renderDirectory` search filter, dashboard recent-table row, `buildCard`, `renderDetail`, new Members card markup + `#member-modal` markup, `extraFieldsHtml`/`renderModalForm`/`addRecord`/`saveEditedRecord`, `IMPORT_FIELD_MAP_EXTRA`/`handleImportFile`, `exportRecords`, `snapshot`/`buildSystem`/`TOOLS`/`execTool`'s `add_record`, `SEED_RECORDS`

## Verification
1. Run the updated `supabase_schema.sql`; spot-check a couple of migrated customer rows in the Supabase table editor — `members[0]` should match what used to be in `name`/`role`/`email`/`phone`, and `name` should now equal `company`.
2. Load the app: Customers kanban/directory/dashboard should show company as the bold primary line and the first member's name/title underneath (or an em dash for the couple of seed rows without a prior contact).
3. Open a customer's detail page: confirm the Members card lists the migrated member, the "+ Add Member" button opens the modal, submitting adds a second member and an activity log entry, and it's saved to Supabase.
4. Add a new customer through the modal: confirm the form no longer shows Contact/Role/Email/Phone, confirm the Subscription field swaps between period/date as you toggle Segment, and confirm the record saves with `members:[]`.
5. Ask the chatbot to add a new Enterprise/SaaS customer and confirm the right subscription field is set; ask it a question referencing a migrated contact by name (e.g. "what's the status for Sara Rashid") and confirm `findRecord`'s members fallback resolves it to the right company.
6. Import a small customers CSV with `name`/`email`/`role` columns; confirm it lands as a member, not a discarded field. Export customers to CSV/Excel and confirm the new columns appear.
