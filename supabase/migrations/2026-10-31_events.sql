-- Version 24: the Events tab.
-- Paste this whole file into the Supabase SQL Editor and click Run. Safe to run more than once.
-- Adds the events table, saving and removing events, and the promotion tasks for Entertainment events.

-- ---------- events (added Oct 2026) ----------
-- The Events tab: a calendar of what's coming up at the pub. Managers add them; everyone sees them.
--   kind: party | entertainment | standard | other
-- Entertainment events get three "Promote" tasks for managers, due 2 weeks, 1 week and 1 day before.
create table if not exists events (
  id text primary key default gen_random_uuid()::text,
  title text not null,
  kind text not null default 'standard' check (kind in ('party','entertainment','standard','other')),
  day date not null,
  start_time time,
  end_time time,
  notes text not null default '',
  added_by text, added_by_name text,
  added_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create index if not exists events_day_idx on events (day);
-- promotion tasks belong to their event (removed with it); event_lead is how many days before the event it's due
alter table tasks add column if not exists event_id text references events(id) on delete cascade;
alter table tasks add column if not exists event_lead int;
do $$
begin
  alter table events enable row level security;
  revoke all on table events from public;
  if exists (select 1 from pg_roles where rolname='anon') then revoke all on table events from anon; end if;
  if exists (select 1 from pg_roles where rolname='authenticated') then revoke all on table events from authenticated; end if;
end $$;

-- Keep an event's promotion tasks in line with the event. Returns how many new tasks it added.
--   Entertainment: one starred task for managers 14, 7 and 1 days before. Ones already in the past aren't added.
--   Moving the event moves the tasks (and un-checks any whose date changed); one that would now be in the past goes away.
--   Any other type: the promotion tasks that aren't done yet go away.
create or replace function _sync_event_tasks(p_ev events, p_me staff) returns int language plpgsql
set search_path = public, extensions as $$
declare lead int; due date; tk tasks; n int := 0; mrole text; label text; today date := _shift_day();
begin
  if p_ev.kind <> 'entertainment' then
    delete from tasks where event_id = p_ev.id and not done;
    return 0;
  end if;
  select id into mrole from roles where id = 'manager';
  if mrole is null then select id into mrole from roles where section = 'mgmt' order by sort, name limit 1; end if;
  foreach lead in array array[14, 7, 1] loop
    due := p_ev.day - lead;
    label := 'Promote ' || p_ev.title || ' · ' ||
             case lead when 14 then '2 weeks out' when 7 then '1 week out' else 'day before' end ||
             ' (' || to_char(p_ev.day, 'Dy Mon FMDD') || ')';
    select * into tk from tasks where event_id = p_ev.id and event_lead = lead limit 1;
    if found then
      if tk.due_date is distinct from due and due < today and not tk.done then
        delete from tasks where id = tk.id;
      elsif tk.due_date is distinct from due then
        update tasks set text = label, due_date = due, done = false, done_day = null, done_due = null, done_until = null,
                         done_by = null, done_by_name = null, done_at = null where id = tk.id;
      else
        update tasks set text = label where id = tk.id;
      end if;
    elsif due >= today then
      insert into tasks (role_id, text, repeat, due_date, important, added_by, added_by_name, event_id, event_lead, added_at)
      values (mrole, label, 'once', due, true, p_me.id, p_me.name, p_ev.id, lead, clock_timestamp());
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- Add (p_id null) or change an event (managers). Returns its id.
create or replace function api_save_event(p_token uuid, p_id text, p_title text, p_kind text, p_day date,
                                          p_start text default null, p_end text default null, p_notes text default '') returns text language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); ev events; k text := lower(coalesce(nullif(trim(p_kind),''), 'standard')); n int;
begin
  if coalesce(trim(p_title),'') = '' then raise exception 'empty'; end if;
  if p_day is null then raise exception 'bad_time'; end if;
  if k not in ('party','entertainment','standard','other') then k := 'other'; end if;
  if nullif(p_id,'') is null then
    insert into events (title, kind, day, start_time, end_time, notes, added_by, added_by_name)
    values (left(trim(p_title), 120), k, p_day, _clean_time(p_start), _clean_time(p_end), left(coalesce(trim(p_notes),''), 1000), me.id, me.name)
    returning * into ev;
    perform _log(me, 'added', ev.title, 'Events');
  else
    update events set title = left(trim(p_title), 120), kind = k, day = p_day, start_time = _clean_time(p_start), end_time = _clean_time(p_end),
                      notes = left(coalesce(trim(p_notes),''), 1000), updated_at = now()
     where id = p_id returning * into ev;
    if not found then raise exception 'not_found'; end if;
    perform _log(me, 'edited', ev.title, 'Events');
  end if;
  n := _sync_event_tasks(ev, me);
  if n > 0 then perform _push_kick(); end if;   -- the other managers hear about the new promotion tasks
  return ev.id;
end $$;

-- Remove an event (managers). Its promotion tasks go with it.
create or replace function api_remove_event(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); ev events;
begin
  delete from events where id = p_id returning * into ev;
  if found then perform _log(me, 'removed', ev.title, 'Events'); end if;
end $$;

-- everything the app shows now includes upcoming events
create or replace function api_state(p_token uuid) returns json language plpgsql
set search_path = public, extensions as $$
declare me staff; mgr boolean;
begin
  me := _me(p_token);
  mgr := _is_manager(me.roles);
  delete from log where at < now() - interval '60 days';
  return json_build_object(
    'me', json_build_object('id', me.id, 'name', me.name, 'roles', me.roles, 'manager', mgr),
    'shift_day', _shift_day(),
    'server_time', now(),
    'roles', coalesce((select json_agg(r order by r.section, r.sort, r.name) from roles r), '[]'),
    'staff', coalesce((select json_agg(json_build_object(
        'id', s.id, 'name', s.name, 'roles', s.roles,
        'has_login', l.staff_id is not null,
        'login_set_by', case when mgr then l.set_by_name end,
        'login_set_at', case when mgr then l.set_at end) order by s.name)
      from staff s left join logins l on l.staff_id = s.id), '[]'),
    'tasks', coalesce((select json_agg(t order by t.added_at, t.id) from tasks t), '[]'),
    'invcats', coalesce((select json_agg(json_build_object('id', c.id, 'name', c.name, 'sort', c.sort,
        'supplier_id', case when mgr then c.supplier_id end) order by c.sort, c.name) from invcats c), '[]'),
    'items', coalesce((select json_agg(json_build_object('id', i.id, 'cat_id', i.cat_id, 'name', i.name, 'unit', i.unit, 'par', i.par, 'on_tap', i.on_tap, 'tapped_at', i.tapped_at, 'tap_label', i.tap_label, 'tap_note', i.tap_note,
        'supplier_id', case when mgr then i.supplier_id end, 'added_at', i.added_at) order by i.added_at, i.name) from items i), '[]'),
    'counts', coalesce((select json_agg(c) from counts c), '[]'),
    'suppliers', case when mgr then coalesce((select json_agg(s order by s.name) from suppliers s), '[]') else '[]' end,
    'shifts', coalesce((select json_agg(_shift_json(s) order by s.start_at) from shifts s
        where (s.start_at at time zone 'America/New_York')::date between _shift_day() - 8 and _shift_day() + 43), '[]'),
    'covers', coalesce((select json_agg(json_build_object('id', w.id, 'at', w.at, 'shift_id', w.shift_id, 'role_id', w.role_id,
                          'from_staff', w.from_staff, 'from_name', w.from_name, 'to_staff', w.to_staff, 'to_name', w.to_name,
                          'start_at', w.start_at, 'end_at', w.end_at) order by w.start_at)
                        from (select * from shift_swaps where _shift_end(start_at, end_at) > now() order by start_at limit 60) w), '[]'),
    'events', coalesce((select json_agg(json_build_object('id', e.id, 'title', e.title, 'kind', e.kind, 'day', e.day,
                          'start_time', e.start_time, 'end_time', e.end_time, 'notes', e.notes,
                          'added_by', e.added_by, 'added_by_name', e.added_by_name, 'added_at', e.added_at)
                          order by e.day, e.start_time nulls first, e.title)
                        from events e where e.day >= _shift_day() - 70), '[]'),
    'log', coalesce((select json_agg(x order by x.at desc) from (
        select id, at, who, who_name, kind, text, place from log
         where mgr or kind <> 'ordered' order by at desc limit 1000) x), '[]')
  );
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
