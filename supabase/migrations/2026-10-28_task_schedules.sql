-- Upgrade: task schedules (weekly, every 2 weeks, monthly, one-time deadlines and due times)
-- Task schedules (added Oct 2026). Safe to re-run on an existing database.
--   repeat:     daily | weekly | biweekly | monthly | once
--   due_date:   next date the task is due (weekly / every 2 weeks / monthly / one-time)
--   due_time:   optional time it's due by; without one, it's due by the end of that shift day (5 AM)
--   anchor_day: day of the month a monthly task falls on
--   done_due / done_until: for repeating tasks, which due date was completed and how long to show it as done
alter table tasks add column if not exists due_date date;
alter table tasks add column if not exists due_time time;
alter table tasks add column if not exists anchor_day int;
alter table tasks add column if not exists done_due date;
alter table tasks add column if not exists done_until timestamptz;
alter table tasks drop constraint if exists tasks_repeat_check;
alter table tasks add constraint tasks_repeat_check check (repeat in ('daily','weekly','biweekly','monthly','once'));


-- ---------- task schedules ----------
-- When a task on date p_date is due. With no time, it's due by the end of that shift day (5 AM the next morning).
-- Times before 5 AM belong to the late end of the shift day, so they fall on the next calendar date.
create or replace function _deadline(p_date date, p_time time) returns timestamptz language sql stable as $$
  select case
    when p_date is null then null
    when p_time is null then ((p_date + 1) + time '05:00') at time zone 'America/New_York'
    when p_time < time '05:00' then ((p_date + 1) + p_time) at time zone 'America/New_York'
    else (p_date + p_time) at time zone 'America/New_York' end
$$;

-- The next (p_dir = 1) or previous (p_dir = -1) due date of a repeating task.
create or replace function _step(p_repeat text, p_date date, p_anchor int, p_dir int) returns date language plpgsql immutable as $$
declare m date; last_day int;
begin
  if p_repeat = 'weekly' then return p_date + 7 * p_dir; end if;
  if p_repeat = 'biweekly' then return p_date + 14 * p_dir; end if;
  if p_repeat = 'monthly' then
    m := (date_trunc('month', p_date) + make_interval(months => p_dir))::date;
    last_day := extract(day from (m + interval '1 month' - interval '1 day'))::int;
    return m + least(coalesce(p_anchor, extract(day from p_date)::int), last_day) - 1;
  end if;
  return p_date;
end $$;

create or replace function _clean_repeat(p_repeat text) returns text language sql immutable as $$
  select case when p_repeat in ('daily','weekly','biweekly','monthly','once') then p_repeat else 'daily' end
$$;

create or replace function _clean_time(p_time text) returns time language sql immutable as $$
  select case when coalesce(p_time,'') ~ '^\d{1,2}:\d{2}' then p_time::time else null end
$$;

-- ---------- shift tasks ----------
create or replace function api_toggle_task(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); t tasks; was_done boolean; rname text; nd date; until timestamptz;
begin
  select * into t from tasks where id = p_id for update;
  if not found then raise exception 'not_found'; end if;

  if t.repeat in ('weekly','biweekly','monthly') then
    was_done := t.done_until is not null and t.done_until > now();
    if was_done then
      -- undo: put the due date back to the one that was just completed
      update tasks set due_date = coalesce(t.done_due, t.due_date), done = false, done_due = null, done_until = null,
                       done_by = null, done_by_name = null, done_at = null where id = p_id;
    else
      if t.due_date is null then t.due_date := _shift_day(); end if;
      -- move to the next due date, skipping any that have already passed
      nd := _step(t.repeat, t.due_date, t.anchor_day, 1);
      while _deadline(nd, t.due_time) < now() loop nd := _step(t.repeat, nd, t.anchor_day, 1); end loop;
      -- show it as done until the next round opens, and at least through today's shift
      until := greatest(_deadline(_step(t.repeat, nd, t.anchor_day, -1), t.due_time), _deadline(_shift_day(), null));
      update tasks set done_due = t.due_date, due_date = nd, done_until = until, done = true,
                       done_by = me.id, done_by_name = me.name, done_at = now() where id = p_id;
    end if;
  else
    was_done := coalesce(case when t.repeat = 'daily' then t.done_day = _shift_day() else t.done end, false);
    if was_done then
      update tasks set done = false, done_day = null, done_by = null, done_by_name = null, done_at = null where id = p_id;
    else
      update tasks set done = true, done_day = _shift_day(), done_by = me.id, done_by_name = me.name, done_at = now() where id = p_id;
    end if;
  end if;

  select name into rname from roles where id = t.role_id;
  perform _log(me, case when was_done then 'undone' else 'done' end, t.text, rname);
end $$;

drop function if exists api_add_task(uuid, text, text, text, text);
create or replace function api_add_task(p_token uuid, p_role_id text, p_text text, p_assignee text, p_repeat text,
                                        p_due_date date default null, p_due_time text default null) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); rname text; rep text := _clean_repeat(p_repeat); dd date := p_due_date;
begin
  if coalesce(trim(p_text),'') = '' then raise exception 'empty'; end if;
  select name into rname from roles where id = p_role_id;
  if rname is null then raise exception 'not_found'; end if;
  if rep = 'daily' then dd := null; elsif rep <> 'once' and dd is null then dd := _shift_day(); end if;
  insert into tasks (role_id, text, assignee, repeat, due_date, due_time, anchor_day, added_by, added_by_name)
  values (p_role_id, trim(p_text), nullif(p_assignee,''), rep, dd, _clean_time(p_due_time),
          case when rep = 'monthly' then extract(day from dd)::int end, me.id, me.name);
  perform _log(me, 'added', trim(p_text), rname);
end $$;

-- Change a task's wording, who it's for, or its schedule (managers, or whoever added it).
-- Changing the schedule starts it fresh as not done.
create or replace function api_update_task(p_token uuid, p_id text, p_text text, p_assignee text, p_repeat text,
                                           p_due_date date default null, p_due_time text default null) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); t tasks; rname text; rep text := _clean_repeat(p_repeat); dd date := p_due_date; tm time := _clean_time(p_due_time);
begin
  select * into t from tasks where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if not (_is_manager(me.roles) or t.added_by = me.id) then raise exception 'managers_only'; end if;
  if coalesce(trim(p_text),'') = '' then raise exception 'empty'; end if;
  if rep = 'daily' then dd := null; elsif rep <> 'once' and dd is null then dd := _shift_day(); end if;
  update tasks set text = trim(p_text), assignee = (select id from staff where id = nullif(p_assignee,'')),
                   repeat = rep, due_date = dd, due_time = tm, anchor_day = case when rep = 'monthly' then extract(day from dd)::int end
   where id = p_id;
  if rep is distinct from t.repeat or dd is distinct from t.due_date or tm is distinct from t.due_time then
    update tasks set done = false, done_day = null, done_due = null, done_until = null, done_by = null, done_by_name = null, done_at = null where id = p_id;
  end if;
  select name into rname from roles where id = t.role_id;
  perform _log(me, 'edited', trim(p_text), rname);
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
