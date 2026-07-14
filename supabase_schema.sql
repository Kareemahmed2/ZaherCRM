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

-- No auth in this phase (explicit decision) — open read/write policies.
-- Revisit once login is added.
-- (drop-then-create makes this script safe to re-run — CREATE POLICY has no IF NOT EXISTS)
drop policy if exists "public read records" on records;
create policy "public read records" on records for select using (true);
drop policy if exists "public write records" on records;
create policy "public write records" on records for insert with check (true);
drop policy if exists "public update records" on records;
create policy "public update records" on records for update using (true) with check (true);
drop policy if exists "public delete records" on records;
create policy "public delete records" on records for delete using (true);

drop policy if exists "public read next_step_options" on next_step_options;
create policy "public read next_step_options" on next_step_options for select using (true);
drop policy if exists "public write next_step_options" on next_step_options;
create policy "public write next_step_options" on next_step_options for insert with check (true);
