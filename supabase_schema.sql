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

-- `nextStep` was left off the customers table below when it was first created —
-- add it here (before the backfill insert that references it) so this script
-- also fixes an already-existing customers table, not just a fresh one.
alter table customers add column if not exists "nextStep" text;

-- One-time backfill from `records` — safe to re-run (on conflict do nothing).
-- `overriding system value` is required once `id` becomes an identity column
-- further down this script (a re-run would otherwise reject the explicit id
-- list) and is a no-op while `id` is still a plain bigint, so this insert
-- stays valid both before and after that later migration runs.
insert into partners (id, portfolio, category, name, company, role, email, phone, stage, model, tier, score, website, region, clients, value, workshops, founders, source, date, notes, activity, created_at, updated_at)
overriding system value
select id, portfolio, category, name, company, role, email, phone, stage, model, tier, score, website, region, clients, value, workshops, founders, source, date, notes, activity, created_at, updated_at
from records where pipeline = 'partners'
on conflict (id) do nothing;

insert into customers (id, name, company, role, email, phone, stage, sector, package, "aiScore", value, "leadSource", "referredBy", segment, "nextStep", date, notes, activity, created_at, updated_at)
overriding system value
select id, name, company, role, email, phone, stage, sector, package, "aiScore", value, "leadSource", "referredBy", segment, "nextStep", date, notes, activity, created_at, updated_at
from records where pipeline = 'customers'
on conflict (id) do nothing;

insert into investors (id, name, company, role, email, phone, stage, "fundSize", thesis, value, source, date, notes, activity, created_at, updated_at)
overriding system value
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

-- Fix: `nextStep` (added above, before the backfill insert) still needs to be
-- populated for customer rows that were already in this table before this script
-- ran — the backfill insert only fills brand-new rows (on conflict do nothing).
-- `records` still has the original values untouched, so pull from there.
-- Safe to re-run — only fills rows that are still null.
update customers c
set "nextStep" = r."nextStep"
from records r
where r.id = c.id and r.pipeline = 'customers'
  and c."nextStep" is null and r."nextStep" is not null;

-- ═══════════════════════════════════════════════════════════════════════
-- Partners & investors: company-based identity + members list (added 2026-07-29)
-- Extends the same company-first / members model that customers already got
-- (2026-07-26 block above) to partners and investors: the organisation name
-- becomes the record's identity, and the single contact that used to live in
-- name/role/email/phone becomes that org's first member. Safe to re-run — the
-- backfill only touches rows whose `members` array is still empty.
-- ═══════════════════════════════════════════════════════════════════════

alter table partners add column if not exists members jsonb not null default '[]'::jsonb;
alter table investors add column if not exists members jsonb not null default '[]'::jsonb;

update partners
set members = jsonb_build_array(jsonb_build_object(
  'name', name,
  'title', coalesce(role, ''),
  'email', coalesce(email, ''),
  'phone', coalesce(phone, ''),
  'linkedin', ''
))
where jsonb_array_length(members) = 0
  and name is distinct from company;

update partners
set name = company, role = '', email = '', phone = ''
where name is distinct from company;

update investors
set members = jsonb_build_array(jsonb_build_object(
  'name', name,
  'title', coalesce(role, ''),
  'email', coalesce(email, ''),
  'phone', coalesce(phone, ''),
  'linkedin', ''
))
where jsonb_array_length(members) = 0
  and name is distinct from company;

update investors
set name = company, role = '', email = '', phone = ''
where name is distinct from company;

-- ═══════════════════════════════════════════════════════════════════════
-- Fix: id columns were plain `bigint primary key` with no sequence — the app
-- assigned ids itself, as `Math.max(...existing ids)+1` computed from
-- whatever was loaded into that browser tab. Two teammates using the CRM at
-- the same time (or one person in two tabs) could compute the same next id,
-- and because the app always writes via `upsert()`, the second write didn't
-- fail — it silently overwrote the first person's record with unrelated
-- data. Postgres-generated identity ids remove the race entirely: the app no
-- longer assigns ids for new records, it reads back whatever Postgres
-- assigned right after insert. (added 2026-07-29)
-- ═══════════════════════════════════════════════════════════════════════

do $$
begin
  if not exists (select 1 from pg_attribute where attrelid='partners'::regclass and attname='id' and attidentity<>'') then
    alter table partners alter column id add generated always as identity;
  end if;
  if not exists (select 1 from pg_attribute where attrelid='customers'::regclass and attname='id' and attidentity<>'') then
    alter table customers alter column id add generated always as identity;
  end if;
  if not exists (select 1 from pg_attribute where attrelid='investors'::regclass and attname='id' and attidentity<>'') then
    alter table investors alter column id add generated always as identity;
  end if;
end $$;

-- Point each table's identity sequence past whatever the highest existing id
-- is, so newly-generated ids never collide with rows that already exist —
-- safe (and worth) re-running any time.
select setval(pg_get_serial_sequence('partners','id'),  coalesce((select max(id) from partners),0)+1,  false);
select setval(pg_get_serial_sequence('customers','id'), coalesce((select max(id) from customers),0)+1, false);
select setval(pg_get_serial_sequence('investors','id'), coalesce((select max(id) from investors),0)+1, false);

-- ═══════════════════════════════════════════════════════════════════════
-- Events pipeline (added 2026-07-30)
-- A fourth pipeline, structurally different from partners/customers/investors:
-- not company-based (no members list, no monetary value) — `name`/`company`
-- hold the event title instead, `stage` is reused as the event's status, and
-- location is either a virtual field group or an in-person field group
-- depending on `format`. Mirrors the partners/customers/investors tables above
-- (same id/activity/timestamp/RLS conventions), just with events-specific columns.
-- ═══════════════════════════════════════════════════════════════════════

create table if not exists events (
  id               bigint generated always as identity primary key,
  name             text not null,
  company          text not null,
  role             text,
  email            text,
  phone            text,
  members          jsonb not null default '[]'::jsonb,
  stage            text not null,
  "eventType"      text,
  description      text,
  "startAt"        timestamptz,
  "endAt"          timestamptz,
  timezone         text,
  format           text check (format in ('Virtual','In-Person')),
  "meetingUrl"     text,
  "meetingPasscode" text,
  "dialIn"         text,
  "venueName"      text,
  address          text,
  "mapUrl"         text,
  capacity         int,
  date             text,
  notes            text,
  activity         jsonb not null default '[]'::jsonb,
  created_at       timestamptz not null default now(),
  updated_at       timestamptz not null default now()
);

drop trigger if exists events_set_updated_at on events;
create trigger events_set_updated_at
  before update on events
  for each row execute function set_updated_at();

alter table events enable row level security;

drop policy if exists "zaher team read events" on events;
create policy "zaher team read events" on events for select using (is_zaher_team());
drop policy if exists "zaher team insert events" on events;
create policy "zaher team insert events" on events for insert with check (is_zaher_team());
drop policy if exists "zaher team update events" on events;
create policy "zaher team update events" on events for update using (is_zaher_team()) with check (is_zaher_team());
drop policy if exists "zaher team delete events" on events;
create policy "zaher team delete events" on events for delete using (is_zaher_team());

-- Event type options (mirrors next_step_options above) — an extensible, team-editable
-- list of event types, seeded with the suggestions from the original spec.
create table if not exists event_type_options (
  id         bigint generated always as identity primary key,
  label      text not null unique,
  created_at timestamptz not null default now()
);

insert into event_type_options (label) values
  ('Webinar'),
  ('Trade Show'),
  ('Product Demo'),
  ('1-on-1 Meeting'),
  ('Conference')
on conflict (label) do nothing;

alter table event_type_options enable row level security;

drop policy if exists "zaher team read event_type_options" on event_type_options;
create policy "zaher team read event_type_options" on event_type_options for select using (is_zaher_team());
drop policy if exists "zaher team insert event_type_options" on event_type_options;
create policy "zaher team insert event_type_options" on event_type_options for insert with check (is_zaher_team());

-- ═══════════════════════════════════════════════════════════════════════
-- Tasks (added 2026-08-04)
-- Discrete to-dos attached to a company record in any pipeline — distinct
-- from the free-text `activity`/notes trail. `record_id` is deliberately not
-- a foreign key: it points at whichever of partners/customers/investors/events
-- `pipeline` names (the same polymorphic-reference pattern `referredBy`
-- already uses), so there's no DB-level cascade delete — the app deletes a
-- record's tasks itself before/when it deletes the record.
-- ═══════════════════════════════════════════════════════════════════════

create table if not exists tasks (
  id           bigint generated always as identity primary key,
  pipeline     text not null check (pipeline in ('partners','customers','investors','events')),
  record_id    bigint not null,
  title        text not null,
  description  text,
  status       text not null default 'Needs to be Done' check (status in ('Needs to be Done','Pending','Done')),
  deadline     date,
  priority     text check (priority in ('High','Medium','Low')),
  created_at   timestamptz not null default now(),
  updated_at   timestamptz not null default now()
);

create index if not exists tasks_pipeline_record_idx on tasks(pipeline, record_id);

drop trigger if exists tasks_set_updated_at on tasks;
create trigger tasks_set_updated_at
  before update on tasks
  for each row execute function set_updated_at();

alter table tasks enable row level security;

drop policy if exists "zaher team read tasks" on tasks;
create policy "zaher team read tasks" on tasks for select using (is_zaher_team());
drop policy if exists "zaher team insert tasks" on tasks;
create policy "zaher team insert tasks" on tasks for insert with check (is_zaher_team());
drop policy if exists "zaher team update tasks" on tasks;
create policy "zaher team update tasks" on tasks for update using (is_zaher_team()) with check (is_zaher_team());
drop policy if exists "zaher team delete tasks" on tasks;
create policy "zaher team delete tasks" on tasks for delete using (is_zaher_team());

-- ═══════════════════════════════════════════════════════════════════════
-- Task assignment + in-app notifications (added 2026-08-11)
-- `team_members` is a lightweight, read-mostly directory of teammate
-- name/email pairs used to populate the "Assign to" picker on a task — kept
-- in sync from auth.users by /api/admin-create-user.js (service-role, so it
-- bypasses RLS) whenever a new account is created, and backfilled once below
-- from whatever accounts already exist. Not a FK target for anything; the
-- app matches tasks.assignedTo (and notifications.recipient_email) to it by
-- email string, same polymorphic-by-value pattern tasks.record_id already
-- uses for pipeline records.
--
-- `notifications` are the actual "you were assigned a task" alerts a
-- teammate sees in the CRM's bell menu. Only the app writes these (on
-- assignment); nothing here auto-generates them from tasks.assignedTo
-- changing, so every assignment path in the app must call createNotification
-- itself.
-- ═══════════════════════════════════════════════════════════════════════

alter table tasks add column if not exists "assignedTo" text;

create table if not exists team_members (
  id         bigint generated always as identity primary key,
  name       text not null,
  email      text not null unique,
  created_at timestamptz not null default now()
);

alter table team_members enable row level security;

drop policy if exists "zaher team read team_members" on team_members;
create policy "zaher team read team_members" on team_members for select using (is_zaher_team());

-- One-time backfill from auth.users for accounts created before this table existed
-- (readable here because the SQL editor runs with elevated privileges). Safe to re-run.
insert into team_members (name, email)
select coalesce(nullif(raw_user_meta_data->>'name',''), split_part(email,'@',1)), email
from auth.users
where email ilike '%@zaher.ai'
on conflict (email) do nothing;

create table if not exists notifications (
  id             bigint generated always as identity primary key,
  recipient_email text not null,
  message        text not null,
  pipeline       text,
  record_id      bigint,
  task_id        bigint,
  read           boolean not null default false,
  created_at     timestamptz not null default now()
);

create index if not exists notifications_recipient_idx on notifications(recipient_email, read);

alter table notifications enable row level security;

-- Recipients only ever see/manage their own notifications (checked against the JWT email,
-- same as is_zaher_team() does) — but *creating* one is inherently about someone else's inbox
-- (whoever assigns a task notifies the assignee, not themselves), so the insert policy is
-- just "any authenticated zaher team member", not restricted to the recipient.
drop policy if exists "own notifications read" on notifications;
create policy "own notifications read" on notifications for select
  using (is_zaher_team() and recipient_email = (auth.jwt() ->> 'email'));
drop policy if exists "zaher team insert notifications" on notifications;
create policy "zaher team insert notifications" on notifications for insert with check (is_zaher_team());
drop policy if exists "own notifications update" on notifications;
create policy "own notifications update" on notifications for update
  using (is_zaher_team() and recipient_email = (auth.jwt() ->> 'email'))
  with check (is_zaher_team() and recipient_email = (auth.jwt() ->> 'email'));

-- ═══════════════════════════════════════════════════════════════════════
-- Reachout tag (added 2026-08-04)
-- Free-text like `stage` (no check constraint, so a third value can be added
-- later without a migration) — the app itself only ever writes 'Reachout
-- Priority' or 'Reachout Done'. Set only from the Pipeline tab's kanban
-- cards; used there to sort a tagged record to the top (Priority) or bottom
-- (Done) of its stage column. All four entity tables get it, including events.
-- ═══════════════════════════════════════════════════════════════════════

alter table partners add column if not exists tag text;
alter table customers add column if not exists tag text;
alter table investors add column if not exists tag text;
alter table events add column if not exists tag text;

-- ═══════════════════════════════════════════════════════════════════════
-- Custom labels (added 2026-08-11)
-- Free-form, multi-value labels a team member can attach to any record in any of the four
-- pipelines — distinct from `tag` above (a fixed two-value enum set only from the kanban card)
-- and from `category`/`sector`/etc (fixed per-pipeline classification fields). Labels are
-- arbitrary and shared across all four pipelines, so they need their own array column rather
-- than reusing any existing field.
--
-- `label_options` is a team-editable canonical list (mirrors next_step_options/
-- event_type_options) so the same label reads identically everywhere it's used instead of
-- drifting into near-duplicate free-text variants — important since labels are meant to power
-- filtering, and a typo'd label silently splits a filter into two.
-- ═══════════════════════════════════════════════════════════════════════

alter table partners add column if not exists labels jsonb not null default '[]'::jsonb;
alter table customers add column if not exists labels jsonb not null default '[]'::jsonb;
alter table investors add column if not exists labels jsonb not null default '[]'::jsonb;
alter table events add column if not exists labels jsonb not null default '[]'::jsonb;

create table if not exists label_options (
  id         bigint generated always as identity primary key,
  label      text not null unique,
  created_at timestamptz not null default now()
);

alter table label_options enable row level security;

drop policy if exists "zaher team read label_options" on label_options;
create policy "zaher team read label_options" on label_options for select using (is_zaher_team());
drop policy if exists "zaher team insert label_options" on label_options;
create policy "zaher team insert label_options" on label_options for insert with check (is_zaher_team());
