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
  created_at   timestamptz not null default now()
);

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
create policy "public read records" on records for select using (true);
create policy "public write records" on records for insert with check (true);
create policy "public update records" on records for update using (true) with check (true);
create policy "public delete records" on records for delete using (true);

create policy "public read next_step_options" on next_step_options for select using (true);
create policy "public write next_step_options" on next_step_options for insert with check (true);
