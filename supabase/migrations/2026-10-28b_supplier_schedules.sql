-- Upgrade: supplier order schedules (every day, weekly, every 2 weeks, monthly, one time)
-- Supplier order schedules (added Oct 2026). Safe to re-run on an existing database.
--   schedule:        daily | weekly (on the chosen days) | biweekly | monthly | once
--   start_date:      first order date for every-2-weeks, monthly and one-time schedules
--   schedule_set_at: when the schedule last changed, so a new schedule starts with nothing marked ordered
alter table suppliers add column if not exists schedule text not null default 'weekly';
alter table suppliers add column if not exists start_date date;
alter table suppliers add column if not exists schedule_set_at timestamptz;  -- existing suppliers keep their current ordered status
alter table suppliers alter column schedule_set_at set default now();
alter table suppliers drop constraint if exists suppliers_schedule_check;
alter table suppliers add constraint suppliers_schedule_check check (schedule in ('daily','weekly','biweekly','monthly','once'));

drop function if exists api_save_supplier(uuid, text, text, int[], text, text);
create or replace function api_save_supplier(p_token uuid, p_id text, p_name text, p_days int[], p_cutoff text, p_notes text,
                                             p_schedule text default 'weekly', p_start_date date default null) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
        sched text := case when p_schedule in ('daily','weekly','biweekly','monthly','once') then p_schedule else 'weekly' end;
        sd date := p_start_date; dys int[] := coalesce(p_days, '{}'); old suppliers;
begin
  if coalesce(trim(p_name),'') = '' then raise exception 'empty'; end if;
  if coalesce(p_cutoff,'') !~ '^\d{2}:\d{2}$' then p_cutoff := '14:00'; end if;
  if sched in ('biweekly','monthly','once') then sd := coalesce(sd, _shift_day()); else sd := null; end if;
  if sched <> 'weekly' then dys := '{}'; end if;
  if p_id is null or p_id = '' then
    insert into suppliers (name, days, cutoff, notes, schedule, start_date, schedule_set_at)
    values (trim(p_name), dys, p_cutoff, coalesce(trim(p_notes),''), sched, sd, now());
  else
    select * into old from suppliers where id = p_id;
    if not found then raise exception 'not_found'; end if;
    update suppliers set name = trim(p_name), days = dys, cutoff = p_cutoff, notes = coalesce(trim(p_notes),''),
                         schedule = sched, start_date = sd,
                         schedule_set_at = case when old.schedule is distinct from sched or old.start_date is distinct from sd
                                                  or old.days is distinct from dys or old.cutoff is distinct from p_cutoff
                                                then now() else old.schedule_set_at end
     where id = p_id;
  end if;
end $$;

-- ---------- who may call what ----------
do $$
declare f record; app boolean;
begin
  for f in select p.oid::regprocedure as sig, p.proname from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and (p.proname like 'api\_%' or p.proname like '\_%' or p.proname = 'admin_set_pin') loop
    app := f.proname like 'api\_%';
    execute format('revoke all on function %s from public', f.sig);
    if exists (select 1 from pg_roles where rolname='anon') then
      execute format(case when app then 'grant execute on function %s to anon' else 'revoke all on function %s from anon' end, f.sig);
    end if;
    if exists (select 1 from pg_roles where rolname='authenticated') then
      execute format(case when app then 'grant execute on function %s to authenticated' else 'revoke all on function %s from authenticated' end, f.sig);
    end if;
  end loop;
end $$;

-- api_* functions run with the owner's rights so they can reach the locked tables.
do $$
declare f record;
begin
  for f in select p.oid::regprocedure as sig from pg_proc p join pg_namespace n on n.oid = p.pronamespace
            where n.nspname = 'public' and p.proname like 'api\_%' loop
    execute format('alter function %s security definer', f.sig);
  end loop;
end $$;
