-- Zaher CRM — Supabase schema
-- Run this once in the Supabase SQL editor (Project → SQL Editor → New query).
-- After running, copy your project URL and anon/public key (Project Settings → API)
-- into the SUPABASE_URL / SUPABASE_ANON_KEY placeholders in zaher_crm.html.

create table if not exists records (
  id           bigint primary key,
  pipeline     text not null check (pipeline in ('partners','customers','investors')),
  portfolio    int,
  category     text,
  name         text not null,
  company      text not null,
  role         text,
  email        text,
  phone        text,
  stage        text not null,
  value        numeric,
  source       text,
  date         text,
  notes        text,
  activity     jsonb not null default '[]'::jsonb,
  model        text,
  tier         int,
  score        int,
  website      text,
  region       text,
  clients      text,
  workshops    int,
  founders     int,
  sector       text,
  package      text,
  "aiScore"    int,
  "leadSource" text,
  "referredBy" int,
  "nextStep"   text,
  "fundSize"   text,
  thesis       text,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Safe to re-run against an existing database that predates the updated_at column.
alter table records add column if not exists updated_at timestamptz not null default now();

-- Safe to re-run against an existing database that predates the segment column
-- (customers only — SaaS vs Enterprise).
alter table records add column if not exists segment text;

-- Keeps updated_at current on every edit, including the upsert() the app uses for updates
-- (an upsert's UPDATE branch only touches columns present in the payload, so relying on the
-- app to set updated_at itself would miss any call site that doesn't — the trigger covers all of them).
create or replace function set_records_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists records_set_updated_at on records;
create trigger records_set_updated_at
  before update on records
  for each row execute function set_records_updated_at();

create table if not exists next_step_options (
  id         bigint generated always as identity primary key,
  label      text not null unique,
  created_at timestamptz not null default now()
);

insert into next_step_options (label) values
  ('Send proposal'),
  ('Schedule demo'),
  ('Follow up call'),
  ('Send contract'),
  ('Onboarding kickoff'),
  ('Check in')
on conflict (label) do nothing;

alter table records enable row level security;
alter table next_step_options enable row level security;

-- Email/password login added 2026-07-14 — access is now restricted to authenticated
-- @zaher.ai accounts (checked against the Supabase Auth JWT's email claim, not just
-- the client-side domain gate in zaher_crm.html, since the anon key alone is public
-- and the client-side check can be bypassed by calling the API directly).
create or replace function is_zaher_team()
returns boolean language sql stable as $$
  select auth.role() = 'authenticated' and (auth.jwt() ->> 'email') ilike '%@zaher.ai';
$$;

-- (drop-then-create makes this script safe to re-run — CREATE POLICY has no IF NOT EXISTS)
drop policy if exists "public read records" on records;
drop policy if exists "zaher team read records" on records;
create policy "zaher team read records" on records for select using (is_zaher_team());
drop policy if exists "public write records" on records;
drop policy if exists "zaher team insert records" on records;
create policy "zaher team insert records" on records for insert with check (is_zaher_team());
drop policy if exists "public update records" on records;
drop policy if exists "zaher team update records" on records;
create policy "zaher team update records" on records for update using (is_zaher_team()) with check (is_zaher_team());
drop policy if exists "public delete records" on records;
drop policy if exists "zaher team delete records" on records;
create policy "zaher team delete records" on records for delete using (is_zaher_team());

drop policy if exists "public read next_step_options" on next_step_options;
drop policy if exists "zaher team read next_step_options" on next_step_options;
create policy "zaher team read next_step_options" on next_step_options for select using (is_zaher_team());
drop policy if exists "public write next_step_options" on next_step_options;
drop policy if exists "zaher team insert next_step_options" on next_step_options;
create policy "zaher team insert next_step_options" on next_step_options for insert with check (is_zaher_team());

-- ═══════════════════════════════════════════════════════════════════════
-- Split of `records` into per-entity tables (added 2026-07-20)
-- `records` mixed columns that only apply to some rows (tier/model for
-- partners, aiScore/segment for customers, fundSize/thesis for investors),
-- distinguished only by the `pipeline` column. Replaced with three tables,
-- one per entity, each with only its own columns.
--
-- `records` itself is left in place (not dropped/renamed) as a safety net —
-- once you've verified the row counts below match, you can drop it yourself:
--   select pipeline, count(*) from records group by pipeline;
--   select count(*) from partners; select count(*) from customers; select count(*) from investors;
--
-- Run this whole script BEFORE deploying the updated zaher_crm.html, since
-- the new frontend code reads/writes partners/customers/investors directly.
-- ═══════════════════════════════════════════════════════════════════════

create table if not exists partners (
  id           bigint primary key,
  portfolio    int,
  category     text,
  name         text not null,
  company      text not null,
  role         text,
  email        text,
  phone        text,
  stage        text not null,
  model        text,
  tier         int,
  score        int,
  website      text,
  region       text,
  clients      text,
  value        numeric,
  workshops    int,
  founders     int,
  source       text,
  date         text,
  notes        text,
  activity     jsonb not null default '[]'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table if not exists customers (
  id           bigint primary key,
  name         text not null,
  company      text not null,
  role         text,
  email        text,
  phone        text,
  stage        text not null,
  sector       text,
  package      text,
  "aiScore"    int,
  value        numeric,
  "leadSource" text,
  "referredBy" bigint,
  segment      text,
  "nextStep"   text,
  date         text,
  notes        text,
  activity     jsonb not null default '[]'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create table if not exists investors (
  id           bigint primary key,
  name         text not null,
  company      text not null,
  role         text,
  email        text,
  phone        text,
  stage        text not null,
  "fundSize"   text,
  thesis       text,
  value        numeric,
  source       text,
  date         text,
  notes        text,
  activity     jsonb not null default '[]'::jsonb,
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

-- Shared updated_at trigger for the three new tables (new name — the
-- original set_records_updated_at()/records_set_updated_at trigger on
-- `records` is left untouched during the transition).
create or replace function set_updated_at()
returns trigger as $$
begin
  new.updated_at = now();
  return new;
end;
$$ language plpgsql;

drop trigger if exists partners_set_updated_at on partners;
create trigger partners_set_updated_at
  before update on partners
  for each row execute function set_updated_at();

drop trigger if exists customers_set_updated_at on customers;
create trigger customers_set_updated_at
  before update on customers
  for each row execute function set_updated_at();

drop trigger if exists investors_set_updated_at on investors;
create trigger investors_set_updated_at
  before update on investors
  for each row execute function set_updated_at();

-- One-time backfill from `records` — safe to re-run (on conflict do nothing).
insert into partners (id, portfolio, category, name, company, role, email, phone, stage, model, tier, score, website, region, clients, value, workshops, founders, source, date, notes, activity, created_at, updated_at)
select id, portfolio, category, name, company, role, email, phone, stage, model, tier, score, website, region, clients, value, workshops, founders, source, date, notes, activity, created_at, updated_at
from records where pipeline = 'partners'
on conflict (id) do nothing;

insert into customers (id, name, company, role, email, phone, stage, sector, package, "aiScore", value, "leadSource", "referredBy", segment, "nextStep", date, notes, activity, created_at, updated_at)
select id, name, company, role, email, phone, stage, sector, package, "aiScore", value, "leadSource", "referredBy", segment, "nextStep", date, notes, activity, created_at, updated_at
from records where pipeline = 'customers'
on conflict (id) do nothing;

insert into investors (id, name, company, role, email, phone, stage, "fundSize", thesis, value, source, date, notes, activity, created_at, updated_at)
select id, name, company, role, email, phone, stage, "fundSize", thesis, value, source, date, notes, activity, created_at, updated_at
from records where pipeline = 'investors'
on conflict (id) do nothing;

alter table partners enable row level security;
alter table customers enable row level security;
alter table investors enable row level security;

drop policy if exists "zaher team read partners" on partners;
create policy "zaher team read partners" on partners for select using (is_zaher_team());
drop policy if exists "zaher team insert partners" on partners;
create policy "zaher team insert partners" on partners for insert with check (is_zaher_team());
drop policy if exists "zaher team update partners" on partners;
create policy "zaher team update partners" on partners for update using (is_zaher_team()) with check (is_zaher_team());
drop policy if exists "zaher team delete partners" on partners;
create policy "zaher team delete partners" on partners for delete using (is_zaher_team());

drop policy if exists "zaher team read customers" on customers;
create policy "zaher team read customers" on customers for select using (is_zaher_team());
drop policy if exists "zaher team insert customers" on customers;
create policy "zaher team insert customers" on customers for insert with check (is_zaher_team());
drop policy if exists "zaher team update customers" on customers;
create policy "zaher team update customers" on customers for update using (is_zaher_team()) with check (is_zaher_team());
drop policy if exists "zaher team delete customers" on customers;
create policy "zaher team delete customers" on customers for delete using (is_zaher_team());

drop policy if exists "zaher team read investors" on investors;
create policy "zaher team read investors" on investors for select using (is_zaher_team());
drop policy if exists "zaher team insert investors" on investors;
create policy "zaher team insert investors" on investors for insert with check (is_zaher_team());
drop policy if exists "zaher team update investors" on investors;
create policy "zaher team update investors" on investors for update using (is_zaher_team()) with check (is_zaher_team());
drop policy if exists "zaher team delete investors" on investors;
create policy "zaher team delete investors" on investors for delete using (is_zaher_team());

-- ═══════════════════════════════════════════════════════════════════════
-- Customers: company-based identity + members list (added 2026-07-26)
-- Customers move from a single hardcoded contact (name/role/email/phone)
-- to a company-first record with a `members` list of people at that
-- company. Existing contact data is migrated into `members[0]` rather
-- than dropped. Safe to re-run — the backfill only touches rows whose
-- `members` array is still empty.
-- ═══════════════════════════════════════════════════════════════════════

alter table customers add column if not exists "subscriptionPeriod" text;
alter table customers add column if not exists "subscriptionDate" text;
alter table customers add column if not exists members jsonb not null default '[]'::jsonb;

-- 1. Seed members[0] from the current name/role/email/phone, for rows that
--    still look like the old single-contact shape (members empty, name is
--    a person, not already equal to company).
update customers
set members = jsonb_build_array(jsonb_build_object(
  'name', name,
  'title', coalesce(role, ''),
  'email', coalesce(email, ''),
  'phone', coalesce(phone, ''),
  'linkedin', ''
))
where jsonb_array_length(members) = 0
  and name is distinct from company;

-- 2. Normalize every customer row to the company-first shape: name becomes
--    the company, and the old per-row contact columns are cleared (the
--    columns stay in the schema since they're shared with partners/investors).
update customers
set name = company, role = '', email = '', phone = ''
where name is distinct from company;

-- Customers: website field (added 2026-07-26)
alter table customers add column if not exists website text;

-- Fix: the customers table (created by the table-split migration above) was missing
-- the "nextStep" column that the app has always written on every save, so every
-- upsert to `customers` was failing with PGRST204 ("Could not find the 'nextStep'
-- column"). `records` still has it untouched — backfill from there for any customers
-- row that's missing it (safe to re-run; only fills rows that are still null).
alter table customers add column if not exists "nextStep" text;
update customers c
set "nextStep" = r."nextStep"
from records r
where r.id = c.id and r.pipeline = 'customers'
  and c."nextStep" is null and r."nextStep" is not null;
