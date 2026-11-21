-- Place to Hear · Aspirasi Harian + Aspirasi Wajib Bulanan
-- Jalankan sekali di Supabase SQL Editor.
-- This migration keeps one current/scheduled monthly agenda at a time.
-- Previous agendas remain in the table for audit/history.

begin;

create table if not exists public.monthly_aspiration_agendas (
  id uuid primary key default gen_random_uuid(),
  title text not null check (char_length(btrim(title)) between 1 and 120),
  description text,
  starts_at timestamptz not null,
  ends_at timestamptz not null,
  is_current boolean not null default true,
  created_by uuid references auth.users(id) on delete set null,
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  constraint monthly_aspiration_agendas_valid_window
    check (ends_at > starts_at)
);

-- Only one agenda can be marked current (scheduled, open, or recently closed).
create unique index if not exists monthly_aspiration_agendas_one_current_idx
  on public.monthly_aspiration_agendas (is_current)
  where is_current = true;

alter table public.monthly_aspiration_agendas enable row level security;

grant select on public.monthly_aspiration_agendas to anon, authenticated;

drop policy if exists monthly_aspiration_agendas_read_current
  on public.monthly_aspiration_agendas;
create policy monthly_aspiration_agendas_read_current
  on public.monthly_aspiration_agendas
  for select to anon
  using (is_current = true);

drop policy if exists monthly_aspiration_agendas_read_admin
  on public.monthly_aspiration_agendas;
create policy monthly_aspiration_agendas_read_admin
  on public.monthly_aspiration_agendas
  for select to authenticated
  using (public.is_mpk_admin());

-- Admin-only, transactional schedule replacement.
-- A new schedule becomes the one current agenda; old agendas remain in history.
create or replace function public.save_monthly_aspiration_agenda(
  p_title text,
  p_description text,
  p_starts_at timestamptz,
  p_ends_at timestamptz
)
returns public.monthly_aspiration_agendas
language plpgsql
security definer
set search_path = public, auth
as $$
declare
  v_agenda public.monthly_aspiration_agendas%rowtype;
begin
  if auth.uid() is null or not public.is_mpk_admin() then
    raise exception 'Only an MPK Owner/Admin can schedule a monthly aspiration.'
      using errcode = '42501';
  end if;

  if p_title is null or char_length(btrim(p_title)) = 0 or char_length(btrim(p_title)) > 120 then
    raise exception 'Agenda title must contain 1 to 120 characters.'
      using errcode = '22023';
  end if;

  if p_starts_at is null or p_ends_at is null or p_ends_at <= p_starts_at then
    raise exception 'The closing time must be later than the opening time.'
      using errcode = '22023';
  end if;

  update public.monthly_aspiration_agendas
     set is_current = false,
         updated_at = now()
   where is_current = true;

  insert into public.monthly_aspiration_agendas
    (title, description, starts_at, ends_at, is_current, created_by)
  values
    (btrim(p_title), nullif(btrim(coalesce(p_description, '')), ''),
     p_starts_at, p_ends_at, true, auth.uid())
  returning * into v_agenda;

  return v_agenda;
end;
$$;

revoke all on function public.save_monthly_aspiration_agenda(text, text, timestamptz, timestamptz)
  from public, anon;
grant execute on function public.save_monthly_aspiration_agenda(text, text, timestamptz, timestamptz)
  to authenticated;

-- Add a source label to every aspiration. Existing rows become daily aspirations.
alter table public.aspirations
  add column if not exists aspiration_type text not null default 'daily';

alter table public.aspirations
  add column if not exists monthly_agenda_id uuid;

do $$
begin
  if not exists (
    select 1 from pg_constraint
     where conname = 'aspirations_aspiration_type_check'
       and conrelid = 'public.aspirations'::regclass
  ) then
    alter table public.aspirations
      add constraint aspirations_aspiration_type_check
      check (aspiration_type in ('daily', 'monthly'));
  end if;

  if not exists (
    select 1 from pg_constraint
     where conname = 'aspirations_monthly_agenda_id_fkey'
       and conrelid = 'public.aspirations'::regclass
  ) then
    alter table public.aspirations
      add constraint aspirations_monthly_agenda_id_fkey
      foreign key (monthly_agenda_id)
      references public.monthly_aspiration_agendas(id)
      on delete set null;
  end if;
end;
$$;

create index if not exists aspirations_type_created_at_idx
  on public.aspirations (aspiration_type, created_at desc);

create index if not exists aspirations_monthly_agenda_id_idx
  on public.aspirations (monthly_agenda_id);

-- Replace existing INSERT policies so monthly submissions cannot bypass the schedule.
do $$
declare
  policy_row record;
begin
  for policy_row in
    select policyname
      from pg_policies
     where schemaname = 'public'
       and tablename = 'aspirations'
       and cmd = 'INSERT'
  loop
    execute format(
      'drop policy %I on public.aspirations',
      policy_row.policyname
    );
  end loop;
end;
$$;

create policy aspirations_insert_daily_or_open_monthly
  on public.aspirations
  for insert to anon, authenticated
  with check (
    (
      aspiration_type = 'daily'
      and monthly_agenda_id is null
    )
    or
    (
      aspiration_type = 'monthly'
      and monthly_agenda_id is not null
      and exists (
        select 1
          from public.monthly_aspiration_agendas agenda
         where agenda.id = monthly_agenda_id
           and agenda.is_current = true
           and agenda.starts_at <= statement_timestamp()
           and agenda.ends_at > statement_timestamp()
      )
    )
  );

grant insert on public.aspirations to anon, authenticated;

commit;
