-- ============================================================================
-- Competitor radar v2 — migrate from the 8-axis Arabic-GEO spec to the 7-axis
-- blended spec (Arabic-localization depth + general competitive strength).
--
-- Written against the real supabase_schema.sql at
-- github.com/Kareemahmed2/ZaherCRM (verified 18 Aug 2026), NOT against
-- assumptions. Three things that file settled:
--   * radar columns are smallint with INLINE, AUTO-NAMED check constraints
--     (competitors_radarSurfaceCoverage_check), not hand-named ones
--   * competitor_score_history DOES NOT EXIST in the schema — an earlier
--     migration that would have created it was never applied
--   * dialects / platformsCovered / labels are jsonb, not text[]
--
-- Safe to run once. Non-destructive: nothing is dropped, no scores are lost.
-- Runs in a transaction; check the verification output before committing.
--
--   AXIS MAP (old -> new)
--   1 radarArabicCitation    -> 1 radarArabicCitation     KEEP, REDEFINED (now measured)
--   2 radarContentDepth      -> 2 radarContentDepth       KEEP
--   5 radarSurfaceCoverage   -> 3 radarFeatureBreadth     RENAME + REDEFINE (broader)
--   6 radarTechnicalGeo      -> 4 radarTechnicalGeo       KEEP
--   7 radarAdoptionAccess    -> 5 radarAdoptionAccess     KEEP
--   (new)                    -> 6 radarMarketAuthority    ADD
--   8 radarProvenOutcomes    -> 7 radarProvenOutcomes     KEEP
--   3 radarDialectCoverage   -> RETIRED FROM RADAR, COLUMN KEPT
--   4 radarSovereignModels   -> RETIRED FROM RADAR, COLUMN KEPT
--
-- Why the two retired axes keep their columns: sovereign-model coverage
-- (Jais 2 / ALLaM / Falcon / Fanar) is still the single most consequential
-- thing the weekly scan watches for, and the dialect field went from one
-- commitment to three in a single week. Dropping the columns would delete the
-- early-warning signal along with the axis. They stay as tracked CRM data and
-- simply stop rendering on the radar. To drop them later, see the bottom.
-- ============================================================================

BEGIN;

-- ---------------------------------------------------------------- 1. rename
-- radarSurfaceCoverage measured engine/surface breadth discounted for Arabic.
-- radarFeatureBreadth measures total product surface (engines, analytics,
-- optimization, exports/API) against a single-tool or pure service. Related but
-- not identical, so old values carry over as a starting point and are flagged
-- for re-scoring rather than trusted. Postgres rewrites the inline check's
-- expression to follow the rename automatically; only the constraint's NAME
-- goes stale, which step 1b fixes.
ALTER TABLE competitors RENAME COLUMN "radarSurfaceCoverage" TO "radarFeatureBreadth";

-- 1b. Rename the auto-generated constraint so it still describes its column.
-- Looked up rather than guessed, since the schema never named it explicitly.
DO $$
DECLARE cname text;
BEGIN
  SELECT conname INTO cname
  FROM pg_constraint
  WHERE conrelid = 'competitors'::regclass
    AND contype = 'c'
    AND conname ILIKE '%radarsurfacecoverage%'
  LIMIT 1;

  IF cname IS NOT NULL THEN
    EXECUTE format('ALTER TABLE competitors RENAME CONSTRAINT %I TO %I',
                   cname, 'competitors_radarFeatureBreadth_check');
    RAISE NOTICE 'renamed constraint % -> competitors_radarFeatureBreadth_check', cname;
  ELSE
    RAISE NOTICE 'no radarSurfaceCoverage check constraint found; nothing to rename';
  END IF;
END $$;

-- ---------------------------------------------------------------- 2. add
-- smallint to match every other radar column in the schema.
ALTER TABLE competitors
  ADD COLUMN IF NOT EXISTS "radarMarketAuthority" smallint
    CHECK ("radarMarketAuthority" BETWEEN 0 AND 10),
  -- Compact per-axis provenance, e.g. '1:IND live basket 18 Aug; 2:ART sitemap
  -- 98/49; 6:IND Fortune Series C'. Tiers: IND independent, ART verifiable
  -- artifact, SELF self-reported. Keeps the evidence tier auditable without
  -- seven more columns.
  ADD COLUMN IF NOT EXISTS "radarEvidence" text;

-- ---------------------------------------------------------------- 3. history
-- competitor_score_history is NOT in the current schema. If it is ever added,
-- it must mirror this rename and this new column or radar history will silently
-- stop recording axes 3 and 6. Guarded so this migration is a no-op today
-- rather than an error, and still correct if the table lands first.
DO $$
BEGIN
  IF to_regclass('public.competitor_score_history') IS NULL THEN
    RAISE NOTICE 'competitor_score_history does not exist — skipping. If you add it later, it must carry radarFeatureBreadth and radarMarketAuthority.';
  ELSE
    IF EXISTS (SELECT 1 FROM information_schema.columns
               WHERE table_name = 'competitor_score_history'
                 AND column_name = 'radarSurfaceCoverage') THEN
      ALTER TABLE competitor_score_history
        RENAME COLUMN "radarSurfaceCoverage" TO "radarFeatureBreadth";
    END IF;
    ALTER TABLE competitor_score_history
      ADD COLUMN IF NOT EXISTS "radarMarketAuthority" smallint;
    RAISE NOTICE 'competitor_score_history migrated — CHECK ITS TRIGGER BODY, which may enumerate columns by name.';
  END IF;
END $$;

-- ---------------------------------------------------------------- 4. flags
-- radarFeatureBreadth inherits radarSurfaceCoverage values, but the definitions
-- differ, so every carried-over score is provisional. Stamp them so the next
-- research pass knows what still needs a real look. radarMarketAuthority and
-- the redefined radarArabicCitation stay NULL = NOT MEASURED (never zero).
UPDATE competitors
SET "radarEvidence" =
      CASE WHEN "radarEvidence" IS NULL OR "radarEvidence" = ''
           THEN '3:PROVISIONAL carried over from radarSurfaceCoverage on the v2 migration — needs re-score'
           ELSE "radarEvidence" || ' | 3:PROVISIONAL carried over from radarSurfaceCoverage on the v2 migration — needs re-score'
      END
WHERE "radarFeatureBreadth" IS NOT NULL;

-- ---------------------------------------------------------------- verify
DO $$
DECLARE bad int;
BEGIN
  SELECT count(*) INTO bad FROM competitors WHERE "radarArabicCitation" = 0;
  IF bad > 0 THEN
    RAISE WARNING 'radarArabicCitation has % row(s) scored 0. Under v2 that means "measured, never cited" — confirm those are real measurements, not backfilled nulls.', bad;
  END IF;
END $$;

SELECT
  count(*)                      AS competitors,
  count("radarArabicCitation")  AS axis1_scored,
  count("radarContentDepth")    AS axis2_scored,
  count("radarFeatureBreadth")  AS axis3_scored,
  count("radarTechnicalGeo")    AS axis4_scored,
  count("radarAdoptionAccess")  AS axis5_scored,
  count("radarMarketAuthority") AS axis6_scored,
  count("radarProvenOutcomes")  AS axis7_scored,
  count("radarDialectCoverage") AS retired_dialect_kept,
  count("radarSovereignModels") AS retired_sovereign_kept,
  count("radarEvidence")        AS evidence_stamped
FROM competitors;

COMMIT;

-- ============================================================================
-- NOT RUN. Only if you later decide the retired axes are genuinely dead.
-- Losing radarSovereignModels means losing the weekly early warning on the one
-- lane no competitor has claimed. Do this deliberately, not by default.
--
-- ALTER TABLE competitors DROP COLUMN "radarDialectCoverage";
-- ALTER TABLE competitors DROP COLUMN "radarSovereignModels";
-- ============================================================================
