-- ============================================================
-- Exhale — Supabase schema, RLS, and realtime wiring
-- Run this once in the Supabase Dashboard → SQL Editor.
-- Also enable: Authentication → Sign In / Up → Anonymous Sign-Ins
-- ============================================================

-- ---------- tables ----------

create table if not exists public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  pseudonym text not null,
  age_bracket text,
  topics text[] default '{}',
  language text default 'English',
  region_mode text default 'anywhere',
  region text,
  prefer_similar_age boolean default false,
  onboarded boolean default false,
  created_at timestamptz not null default now()
);

create table if not exists public.match_queue (
  user_id uuid primary key references auth.users(id) on delete cascade,
  topics text[] default '{}',
  language text default 'English',
  created_at timestamptz not null default now()
);

create table if not exists public.matches (
  id uuid primary key default gen_random_uuid(),
  user1_id uuid not null references auth.users(id) on delete cascade,
  user2_id uuid not null references auth.users(id) on delete cascade,
  status text not null default 'active' check (status in ('active','ended')),
  user1_consent boolean not null default false,
  user2_consent boolean not null default false,
  saved boolean not null default false,
  started_at timestamptz not null default now(),
  ended_at timestamptz
);

create table if not exists public.messages (
  id uuid primary key default gen_random_uuid(),
  match_id uuid not null references public.matches(id) on delete cascade,
  sender_id uuid not null references auth.users(id) on delete cascade,
  body text not null check (char_length(body) between 1 and 2000),
  flagged boolean not null default false,
  created_at timestamptz not null default now()
);

create table if not exists public.crisis_flags (
  id uuid primary key default gen_random_uuid(),
  message_id uuid references public.messages(id) on delete set null,
  match_id uuid,
  user_id uuid,
  severity text not null default 'high',
  status text not null default 'open',
  created_at timestamptz not null default now()
);

create table if not exists public.mood_logs (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  mood int not null check (mood between 0 and 4),
  created_at timestamptz not null default now()
);

create table if not exists public.journal_entries (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  text text not null check (char_length(text) between 1 and 4000),
  created_at timestamptz not null default now()
);

create table if not exists public.reflections (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references auth.users(id) on delete cascade,
  match_id uuid,
  text text not null,
  created_at timestamptz not null default now()
);

-- ---------- row level security ----------

alter table public.profiles enable row level security;
alter table public.match_queue enable row level security;
alter table public.matches enable row level security;
alter table public.messages enable row level security;
alter table public.crisis_flags enable row level security;
alter table public.mood_logs enable row level security;
alter table public.journal_entries enable row level security;
alter table public.reflections enable row level security;

-- profiles: read own only (writes go through the backend)
drop policy if exists "read own profile" on public.profiles;
create policy "read own profile" on public.profiles
for select to authenticated using (id = (select auth.uid()));

-- match_queue: read own waiting state only
drop policy if exists "read own queue row" on public.match_queue;
create policy "read own queue row" on public.match_queue
for select to authenticated using (user_id = (select auth.uid()));

-- matches: participants can read
drop policy if exists "participants read matches" on public.matches;
create policy "participants read matches" on public.matches
for select to authenticated
using (user1_id = (select auth.uid()) or user2_id = (select auth.uid()));

-- messages: NO client policies at all — reads and writes only via backend.
-- crisis_flags: NO client policies — moderation/backend only.

-- solo tools: full private CRUD for the owner
drop policy if exists "own mood logs" on public.mood_logs;
create policy "own mood logs" on public.mood_logs
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

drop policy if exists "own journal" on public.journal_entries;
create policy "own journal" on public.journal_entries
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

drop policy if exists "own reflections" on public.reflections;
create policy "own reflections" on public.reflections
for all to authenticated
using (user_id = (select auth.uid()))
with check (user_id = (select auth.uid()));

-- ---------- realtime: broadcast on new messages ----------

create or replace function public.broadcast_new_message()
returns trigger
language plpgsql
security definer
set search_path = public
as $$
begin
  perform realtime.send(
    jsonb_build_object(
      'id', new.id,
      'match_id', new.match_id,
      'sender_id', new.sender_id,
      'body', new.body,
      'flagged', new.flagged,
      'created_at', new.created_at
    ),
    'message_created',
    'match:' || new.match_id::text,
    true
  );
  return new;
end;
$$;

drop trigger if exists messages_realtime_trigger on public.messages;
create trigger messages_realtime_trigger
after insert on public.messages
for each row execute function public.broadcast_new_message();

-- generic broadcast helper for the FastAPI backend (service key only)
create or replace function public.broadcast_event(topic text, event text, payload jsonb)
returns void
language plpgsql
security definer
set search_path = public
as $$
begin
  perform realtime.send(payload, event, topic, true);
end;
$$;

revoke execute on function public.broadcast_event(text, text, jsonb) from public, anon, authenticated;
grant execute on function public.broadcast_event(text, text, jsonb) to service_role;

-- ---------- realtime authorization for private channels ----------

drop policy if exists "receive own broadcasts" on realtime.messages;
create policy "receive own broadcasts" on realtime.messages
for select to authenticated
using (
  realtime.messages.extension = 'broadcast'
  and (
    realtime.topic() = 'user:' || (select auth.uid())::text
    or exists (
      select 1 from public.matches m
      where ('match:' || m.id::text) = realtime.topic()
        and (m.user1_id = (select auth.uid()) or m.user2_id = (select auth.uid()))
    )
  )
);

-- Clients must not publish broadcasts (no INSERT policy on realtime.messages).
