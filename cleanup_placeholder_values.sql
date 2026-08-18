-- One-time cleanup: null out placeholder-only Sector / Lead source values ("-", "—", "---",
-- "N/A", blank-ish) left in the customers table from before the importer started stripping
-- these on the way in. Matches the same isPlaceholderText() check zaher_crm.html now applies
-- at read time (dropdown options, filter panel), so this just cleans up the underlying data
-- to match what the app already treats as "no data".
--
-- Run once in the Supabase SQL editor. Each UPDATE returns the rows it touched so you can see
-- exactly what changed before/after.

update customers
set sector = null
where sector is not null
  and btrim(sector) ~* '^([-—]+|n/?a)$'
returning id, company, sector;

update customers
set "leadSource" = null
where "leadSource" is not null
  and btrim("leadSource") ~* '^([-—]+|n/?a)$'
returning id, company, "leadSource";
