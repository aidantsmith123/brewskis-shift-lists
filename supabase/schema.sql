-- JT Brewskis Shift Lists: database for Supabase
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run.
-- It is safe to run on a brand-new project. Running it again resets nothing it already created,
-- except the functions, which it replaces.
--
-- How it is locked down:
--   * Every table has row level security on and no policies, and the public "anon" and
--     "authenticated" roles have no table privileges, so the app cannot read or write tables directly.
--   * The app only calls the api_* functions below. Each one checks the login session first,
--     and the manager-only ones check that the logged-in person has a Management role.
--   * Login numbers are stored as bcrypt hashes and checked here on the server.

create schema if not exists extensions;
create extension if not exists pgcrypto with schema extensions;

-- ---------- tables ----------
create table if not exists roles (
  id text primary key,
  name text not null,
  section text not null check (section in ('mgmt','foh','boh')),
  sort int not null default 0
);
create table if not exists staff (
  id text primary key default gen_random_uuid()::text,
  name text not null,
  roles text[] not null default '{}',
  created_at timestamptz not null default now()
);
create table if not exists logins (
  staff_id text primary key references staff(id) on delete cascade,
  pin_hash text not null,
  version int not null default 1,
  set_by_name text,
  set_at timestamptz not null default now()
);
create table if not exists sessions (
  token uuid primary key default gen_random_uuid(),
  staff_id text not null references staff(id) on delete cascade,
  pin_version int not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null
);
create table if not exists login_failures (at timestamptz not null default now());
create table if not exists tasks (
  id text primary key default gen_random_uuid()::text,
  role_id text not null references roles(id) on delete cascade,
  text text not null,
  assignee text references staff(id) on delete set null,
  repeat text not null default 'daily',
  added_by text, added_by_name text,
  added_at timestamptz not null default now(),
  done boolean not null default false,
  done_day date, done_by text, done_by_name text, done_at timestamptz
);
create table if not exists invcats (
  id text primary key default gen_random_uuid()::text,
  name text not null,
  sort int not null default 0
);
create table if not exists suppliers (
  id text primary key default gen_random_uuid()::text,
  name text not null,
  days int[] not null default '{}',
  cutoff text not null default '14:00',
  notes text not null default '',
  last_ordered_at timestamptz, last_ordered_by text, last_ordered_by_name text
);
create table if not exists items (
  id text primary key default gen_random_uuid()::text,
  cat_id text not null references invcats(id) on delete cascade,
  name text not null,
  unit text not null default '',
  par numeric,
  supplier_id text references suppliers(id) on delete set null,
  added_at timestamptz not null default now()
);
create table if not exists counts (
  item_id text primary key references items(id) on delete cascade,
  on_hand numeric not null,
  counted_by text, counted_by_name text,
  counted_at timestamptz not null default now()
);
create table if not exists log (
  id bigserial primary key,
  at timestamptz not null default now(),
  day date not null,
  who text, who_name text,
  kind text not null,
  text text not null default '',
  place text not null default ''
);
create index if not exists log_at_idx on log (at desc);

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
-- v22: the Tasks tab. Managers add the significant tasks; a task can be for everyone (no role), and can be starred as important.
alter table tasks alter column role_id drop not null;
alter table tasks add column if not exists important boolean not null default false;

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

do $$
declare t text;
begin
  foreach t in array array['roles','staff','logins','sessions','login_failures','tasks','invcats','suppliers','items','counts','log'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on table %I from public', t);
    if exists (select 1 from pg_roles where rolname='anon') then execute format('revoke all on table %I from anon', t); end if;
    if exists (select 1 from pg_roles where rolname='authenticated') then execute format('revoke all on table %I from authenticated', t); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname='anon') then revoke all on sequence log_id_seq from anon; end if;
  if exists (select 1 from pg_roles where rolname='authenticated') then revoke all on sequence log_id_seq from authenticated; end if;
end $$;

-- ---------- helpers (not callable from the app) ----------
create or replace function _shift_day() returns date language sql stable as $$
  select ((now() at time zone 'America/New_York') - interval '5 hours')::date
$$;

create or replace function _is_manager(p_roles text[]) returns boolean language sql stable
set search_path = public, extensions as $$
  select exists (select 1 from roles r where r.id = any(p_roles) and r.section = 'mgmt')
$$;

create or replace function _me(p_token uuid) returns staff language plpgsql stable
set search_path = public, extensions as $$
declare s staff;
begin
  select st.* into s from sessions x
    join staff st on st.id = x.staff_id
    join logins l on l.staff_id = st.id and l.version = x.pin_version
   where x.token = p_token and x.expires_at > now();
  if not found then raise exception 'not_logged_in'; end if;
  return s;
end $$;

create or replace function _mgr(p_token uuid) returns staff language plpgsql stable
set search_path = public, extensions as $$
declare s staff;
begin
  s := _me(p_token);
  if not _is_manager(s.roles) then raise exception 'managers_only'; end if;
  return s;
end $$;

create or replace function _log(p_who staff, p_kind text, p_text text, p_place text) returns void language sql
set search_path = public, extensions as $$
  insert into log (day, who, who_name, kind, text, place) values (_shift_day(), p_who.id, p_who.name, p_kind, coalesce(p_text,''), coalesce(p_place,''))
$$;

-- At least one manager must always be able to log in.
create or replace function _keep_a_manager() returns void language plpgsql
set search_path = public, extensions as $$
begin
  if not exists (select 1 from staff s join logins l on l.staff_id = s.id where _is_manager(s.roles)) then
    raise exception 'last_manager';
  end if;
end $$;

create or replace function _find_pin(p_pin text, p_except text) returns text language sql stable
set search_path = public, extensions as $$
  select staff_id from logins where pin_hash = crypt(p_pin, pin_hash) and staff_id is distinct from p_except limit 1
$$;

create or replace function _slug(p_name text, p_table text) returns text language plpgsql
set search_path = public, extensions as $$
declare base text := coalesce(nullif(trim(both '-' from regexp_replace(lower(p_name), '[^a-z0-9]+', '-', 'g')), ''), 'item');
        candidate text := base; taken boolean;
begin
  loop
    execute format('select exists (select 1 from %I where id = $1)', p_table) into taken using candidate;
    exit when not taken;
    candidate := base || '-' || substr(md5(random()::text), 1, 4);
  end loop;
  return candidate;
end $$;

-- ---------- login ----------
create or replace function api_login(p_pin text) returns json language plpgsql
set search_path = public, extensions as $$
declare sid text; v int; tok uuid;
begin
  delete from login_failures where at < now() - interval '10 minutes';
  delete from sessions where expires_at < now();
  if (select count(*) from login_failures where at > now() - interval '1 minute') >= 15 then
    return json_build_object('error','too_many_attempts');
  end if;
  if p_pin !~ '^\d{4,6}$' then return json_build_object('error','wrong_number'); end if;
  sid := _find_pin(p_pin, null);
  if sid is null then
    insert into login_failures default values;
    return json_build_object('error','wrong_number');
  end if;
  select version into v from logins where staff_id = sid;
  insert into sessions (staff_id, pin_version, expires_at) values (sid, v, now() + interval '16 hours') returning token into tok;
  return json_build_object('token', tok, 'staff_id', sid);
end $$;

create or replace function api_logout(p_token uuid) returns void language sql
set search_path = public, extensions as $$ delete from sessions where token = p_token $$;

-- ---------- everything the app shows ----------
create or replace function api_state(p_token uuid) returns json language plpgsql
set search_path = public, extensions as $$
declare me staff; mgr boolean; cb boolean;
begin
  me := _me(p_token);
  mgr := _is_manager(me.roles);
  cb := _can_cash_book(me.id);
  delete from log where at < now() - interval '60 days';
  return json_build_object(
    'me', json_build_object('id', me.id, 'name', me.name, 'roles', me.roles, 'manager', mgr, 'cash_book', cb),
    -- daily cash: only for Aidan, Tom and Mandy (cash_book_access)
    'daily_cash', case when cb then coalesce((select json_agg(dc order by dc.day desc) from daily_cash dc where dc.day >= _shift_day() - 120), '[]') else '[]' end,
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
                          'added_by', e.added_by, 'added_by_name', e.added_by_name, 'added_at', e.added_at,
                          'repeat', e.repeat, 'repeat_until', e.repeat_until, 'skip_dates', e.skip_dates, 'promote', e.promote)
                          order by e.day, e.start_time nulls first, e.title)
                        from events e where e.day >= _shift_day() - 70
                           or (e.repeat <> 'none' and (e.repeat_until is null or e.repeat_until >= _shift_day() - 70))), '[]'),
    'parties', case when mgr then coalesce((select json_agg(p order by p.day, p.start_time nulls first) from parties p
                          where p.status = 'inquiry' or coalesce(p.day, (p.submitted_at at time zone 'America/New_York')::date) >= _shift_day() - 70), '[]')
               else coalesce((select json_agg(json_build_object('id', p.id, 'status', p.status, 'host_name', p.host_name, 'occasion', p.occasion,
                          'day', p.day, 'start_time', p.start_time, 'end_time', p.end_time, 'guests', p.guests, 'package', p.package,
                          'notes', p.notes, 'event_id', p.event_id) order by p.day)
                        from parties p where p.status in ('hold','booked') and p.day >= _shift_day() - 1), '[]') end,
    'settings', case when mgr then json_build_object(
                  'party_deposit', (select value from app_settings where name = 'party_deposit'),
                  'party_form_last', (select max(submitted_at) from parties where source = 'form')) else '{}'::json end,
    -- managers: open alerts plus the last 3 days; everyone else: what they sent in the last 2 days
    'alerts', coalesce((select json_agg(a order by a.at desc) from manager_alerts a
                        where case when mgr then a.handled_at is null or a.at > now() - interval '3 days'
                                   else a.from_id = me.id and a.at > now() - interval '2 days' end), '[]'),
    'drawers', coalesce((select json_agg(json_build_object('id', d.id, 'name', d.name, 'bank', d.bank) order by d.sort, d.name)
                        from drawers d where d.active), '[]'),
    -- managers: the last 3 months of cash-outs; everyone else: tonight's
    'cashouts', coalesce((select json_agg(c order by c.day desc, c.drawer_name) from cashouts c
                          where c.day >= _shift_day() - case when mgr then 92 else 0 end), '[]'),
    'log', coalesce((select json_agg(x order by x.at desc) from (
        select id, at, who, who_name, kind, text, place from log
         where mgr or (kind <> 'ordered' and place not in ('Cash','Alerts')) order by at desc limit 1000) x), '[]')
  );
end $$;

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
  perform _log(me, case when was_done then 'undone' else 'done' end, t.text, coalesce(rname, 'Tasks'));
  if not was_done and t.added_by is distinct from me.id and t.added_by is not null then perform _push_kick(); end if;   -- tell whoever added it
end $$;

drop function if exists api_add_task(uuid, text, text, text, text);
drop function if exists api_add_task(uuid, text, text, text, text, date, text);
-- Managers add the tasks worth tracking. No role means it's for everyone.
create or replace function api_add_task(p_token uuid, p_role_id text, p_text text, p_assignee text, p_repeat text,
                                        p_due_date date default null, p_due_time text default null, p_important boolean default false) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); rid text; rname text; rep text := _clean_repeat(p_repeat); dd date := p_due_date;
begin
  if coalesce(trim(p_text),'') = '' then raise exception 'empty'; end if;
  if nullif(p_role_id,'') is not null then
    select id, name into rid, rname from roles where id = p_role_id;
    if rid is null then raise exception 'not_found'; end if;
  end if;
  if rep = 'daily' then dd := null; elsif rep <> 'once' and dd is null then dd := _shift_day(); end if;
  insert into tasks (role_id, text, assignee, repeat, due_date, due_time, anchor_day, important, added_by, added_by_name)
  values (rid, trim(p_text), (select id from staff where id = nullif(p_assignee,'')), rep, dd, _clean_time(p_due_time),
          case when rep = 'monthly' then extract(day from dd)::int end, coalesce(p_important, false), me.id, me.name);
  perform _log(me, 'added', trim(p_text), coalesce(rname, 'Tasks'));
  perform _push_kick();   -- tell the people it's for right away
end $$;

-- Change a task (managers). p_role_id '-' and p_important null keep what's there (older app versions don't send them).
-- Changing the schedule starts it fresh as not done.
drop function if exists api_update_task(uuid, text, text, text, text, date, text);
create or replace function api_update_task(p_token uuid, p_id text, p_text text, p_assignee text, p_repeat text,
                                           p_due_date date default null, p_due_time text default null,
                                           p_role_id text default '-', p_important boolean default null) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); t tasks; rid text; rname text; rep text := _clean_repeat(p_repeat); dd date := p_due_date; tm time := _clean_time(p_due_time);
begin
  select * into t from tasks where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if coalesce(trim(p_text),'') = '' then raise exception 'empty'; end if;
  rid := case when p_role_id = '-' then t.role_id else (select id from roles where id = nullif(p_role_id,'')) end;
  if rep = 'daily' then dd := null; elsif rep <> 'once' and dd is null then dd := _shift_day(); end if;
  update tasks set text = trim(p_text), assignee = (select id from staff where id = nullif(p_assignee,'')), role_id = rid,
                   important = coalesce(p_important, important),
                   repeat = rep, due_date = dd, due_time = tm, anchor_day = case when rep = 'monthly' then extract(day from dd)::int end
   where id = p_id;
  if rep is distinct from t.repeat or dd is distinct from t.due_date or tm is distinct from t.due_time then
    update tasks set done = false, done_day = null, done_due = null, done_until = null, done_by = null, done_by_name = null, done_at = null where id = p_id;
  end if;
  select name into rname from roles where id = rid;
  perform _log(me, 'edited', trim(p_text), coalesce(rname, 'Tasks'));
end $$;

-- Star or unstar a task (managers).
create or replace function api_star_task(p_token uuid, p_id text, p_important boolean) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin update tasks set important = coalesce(p_important, false) where id = p_id; end $$;

create or replace function api_add_starter_tasks(p_token uuid, p_role_id text, p_texts text[]) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  insert into tasks (role_id, text, repeat, added_by, added_by_name, added_at)
  select p_role_id, x, 'daily', me.id, me.name, clock_timestamp() + n * interval '1 millisecond'
    from unnest(p_texts) with ordinality as u(x, n) where trim(x) <> '';
end $$;

create or replace function api_remove_task(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); t tasks; rname text;
begin
  select * into t from tasks where id = p_id;
  if not found then return; end if;
  if not _is_manager(me.roles) then raise exception 'managers_only'; end if;
  delete from tasks where id = p_id;
  select name into rname from roles where id = t.role_id;
  perform _log(me, 'removed', t.text, coalesce(rname, 'Tasks'));
end $$;

-- ---------- inventory counts (everyone) ----------
create or replace function api_set_count(p_token uuid, p_item_id text, p_on_hand numeric) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); it items; v numeric := greatest(coalesce(p_on_hand,0), 0);
begin
  select * into it from items where id = p_item_id;
  if not found then raise exception 'not_found'; end if;
  insert into counts (item_id, on_hand, counted_by, counted_by_name, counted_at) values (p_item_id, v, me.id, me.name, now())
  on conflict (item_id) do update set on_hand = excluded.on_hand, counted_by = excluded.counted_by, counted_by_name = excluded.counted_by_name, counted_at = now();
  perform _log(me, 'count', it.name || ': ' || case when v = trunc(v) then trunc(v)::text else trim(trailing '0' from v::text) end || case when it.unit <> '' then ' ' || it.unit else '' end, 'Inventory');
end $$;

-- ---------- managers: people, roles, login numbers ----------
create or replace function api_add_staff(p_token uuid, p_name text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  if coalesce(trim(p_name),'') = '' then raise exception 'empty'; end if;
  insert into staff (name) values (trim(p_name));
end $$;

create or replace function api_remove_staff(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  delete from staff where id = p_id;
  perform _keep_a_manager();
end $$;

create or replace function api_set_staff_roles(p_token uuid, p_id text, p_roles text[]) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  update staff set roles = (select coalesce(array_agg(distinct r), '{}') from unnest(p_roles) r where exists (select 1 from roles where id = r)) where id = p_id;
  perform _keep_a_manager();
end $$;

create or replace function api_set_pin(p_token uuid, p_id text, p_pin text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  if p_pin !~ '^\d{4,6}$' then raise exception 'bad_number'; end if;
  if not exists (select 1 from staff where id = p_id) then raise exception 'not_found'; end if;
  if _find_pin(p_pin, p_id) is not null then raise exception 'number_taken'; end if;
  insert into logins (staff_id, pin_hash, version, set_by_name, set_at) values (p_id, crypt(p_pin, gen_salt('bf', 8)), 1, me.name, now())
  on conflict (staff_id) do update set pin_hash = excluded.pin_hash, version = logins.version + 1, set_by_name = excluded.set_by_name, set_at = now();
end $$;

create or replace function api_clear_pin(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  delete from logins where staff_id = p_id;
  delete from sessions where staff_id = p_id;
  perform _keep_a_manager();
end $$;

create or replace function api_add_role(p_token uuid, p_name text, p_section text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  if coalesce(trim(p_name),'') = '' then raise exception 'empty'; end if;
  insert into roles (id, name, section, sort)
  values (_slug(p_name, 'roles'), trim(p_name), case when p_section in ('mgmt','foh','boh') then p_section else 'foh' end,
          (select coalesce(max(sort),0) + 1 from roles where section = p_section));
end $$;

create or replace function api_remove_role(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  update staff set roles = array_remove(roles, p_id) where p_id = any(roles);
  delete from roles where id = p_id;
  perform _keep_a_manager();
end $$;

-- ---------- managers: inventory lists, items, suppliers ----------
create or replace function api_add_category(p_token uuid, p_name text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  if coalesce(trim(p_name),'') = '' then raise exception 'empty'; end if;
  insert into invcats (id, name, sort) values (_slug(p_name, 'invcats'), trim(p_name), (select coalesce(max(sort),0) + 1 from invcats));
end $$;

create or replace function api_remove_category(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin delete from invcats where id = p_id; end $$;

create or replace function api_add_items(p_token uuid, p_cat_id text, p_items jsonb) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  insert into items (cat_id, name, unit, par, supplier_id, added_at)
  select p_cat_id, trim(x->>'name'), coalesce(trim(x->>'unit'),''), nullif(x->>'par','')::numeric,
         (select id from suppliers where id = nullif(x->>'supplier_id','')),
         clock_timestamp() + n * interval '1 millisecond'
    from jsonb_array_elements(p_items) with ordinality as e(x, n) where coalesce(trim(x->>'name'),'') <> '';
end $$;

create or replace function api_update_item(p_token uuid, p_id text, p_name text, p_unit text, p_par numeric, p_supplier_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  update items set name = coalesce(nullif(trim(p_name),''), name), unit = coalesce(trim(p_unit),''), par = p_par,
                   supplier_id = (select id from suppliers where id = nullif(p_supplier_id,''))
   where id = p_id;
end $$;

create or replace function api_remove_item(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin delete from items where id = p_id; end $$;

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

create or replace function api_remove_supplier(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin delete from suppliers where id = p_id; end $$;

create or replace function api_mark_ordered(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); sname text;
begin
  update suppliers set last_ordered_at = now(), last_ordered_by = me.id, last_ordered_by_name = me.name where id = p_id returning name into sname;
  if sname is null then raise exception 'not_found'; end if;
  perform _log(me, 'ordered', sname, 'Inventory');
end $$;

-- ---------- for you, in the SQL Editor only: give a person a login number ----------
-- Example:  select admin_set_pin('Aidan', '4821');
create or replace function admin_set_pin(p_name text, p_pin text) returns text language plpgsql
set search_path = public, extensions as $$
declare sid text; n int;
begin
  if p_pin !~ '^\d{4,6}$' then raise exception 'Use 4 to 6 digits'; end if;
  select count(*), min(id) into n, sid from staff where lower(name) = lower(trim(p_name));
  if n = 0 then raise exception 'Nobody named % on the team', p_name; end if;
  if n > 1 then raise exception 'More than one person is named %', p_name; end if;
  if _find_pin(p_pin, sid) is not null then raise exception 'That number is already taken'; end if;
  insert into logins (staff_id, pin_hash, version, set_by_name, set_at) values (sid, crypt(p_pin, gen_salt('bf', 8)), 1, 'Setup', now())
  on conflict (staff_id) do update set pin_hash = excluded.pin_hash, version = logins.version + 1, set_by_name = 'Setup', set_at = now();
  return 'Login number saved for ' || trim(p_name);
end $$;

-- ---------- manager notifications (added Oct 2026) ----------
-- Each manager phone that turns on notifications gets a row in push_subs with its own settings.
-- The "notify" Edge Function runs every 15 minutes, calls _push_collect() for what's due, and sends it.
-- push_sent remembers what was already sent so nothing goes out twice.
create table if not exists push_subs (
  endpoint text primary key,
  staff_id text not null references staff(id) on delete cascade,
  p256dh text not null,
  auth text not null,
  prefs jsonb not null default '{}',
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now()
);
create table if not exists push_sent (key text primary key, sent_at timestamptz not null default now());
-- Signing keys and the scheduler's password live here. Only the database owner can read it.
create table if not exists app_secrets (name text primary key, value text not null);

do $$
declare t text;
begin
  foreach t in array array['push_subs','push_sent','app_secrets'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on table %I from public', t);
    if exists (select 1 from pg_roles where rolname='anon') then execute format('revoke all on table %I from anon', t); end if;
    if exists (select 1 from pg_roles where rolname='authenticated') then execute format('revoke all on table %I from authenticated', t); end if;
  end loop;
end $$;

create or replace function _shift_day_at(p_now timestamptz) returns date language sql stable as $$
  select ((p_now at time zone 'America/New_York') - interval '5 hours')::date
$$;

-- Settings with defaults filled in and junk thrown out.
create or replace function _push_prefs(p jsonb) returns jsonb language plpgsql immutable as $$
declare d jsonb := '{"orders":true,"lead_hours":2,"overdue":true,"out":true,"summary":true,"swaps":true,"coverage":true,"tasks":true,"cash":true,"staff":true,"cashbook":true,"done":true,"summary_time":"09:00","quiet":true,"quiet_start":"00:00","quiet_end":"08:00"}';
        r jsonb := d; k text;
begin
  p := coalesce(p, '{}');
  foreach k in array array['orders','overdue','out','summary','swaps','coverage','tasks','cash','staff','cashbook','done','quiet'] loop
    if jsonb_typeof(p->k) = 'boolean' then r := jsonb_set(r, array[k], p->k); end if;
  end loop;
  if jsonb_typeof(p->'lead_hours') = 'number' then r := jsonb_set(r, '{lead_hours}', to_jsonb(least(greatest((p->>'lead_hours')::numeric::int, 1), 48))); end if;
  foreach k in array array['summary_time','quiet_start','quiet_end'] loop
    if coalesce(p->>k,'') ~ '^\d{1,2}:\d{2}$' then r := jsonb_set(r, array[k], to_jsonb(to_char((p->>k)::time, 'HH24:MI'))); end if;
  end loop;
  return r;
end $$;

create or replace function _push_quiet(p jsonb, t time) returns boolean language sql immutable as $$
  select coalesce((p->>'quiet')::boolean, false) and case
    when (p->>'quiet_start')::time = (p->>'quiet_end')::time then false
    when (p->>'quiet_start')::time < (p->>'quiet_end')::time then t >= (p->>'quiet_start')::time and t < (p->>'quiet_end')::time
    else t >= (p->>'quiet_start')::time or t < (p->>'quiet_end')::time end
$$;

-- "2:00 PM today", "11:00 AM tomorrow", "2:00 PM Tue"
create or replace function _fmt_due(p_at timestamptz, p_now timestamptz) returns text language sql stable as $$
  select to_char(p_at at time zone 'America/New_York', 'FMHH12:MI AM') || ' ' ||
    case (p_at at time zone 'America/New_York')::date - (p_now at time zone 'America/New_York')::date
      when 0 then 'today' when 1 then 'tomorrow'
      else to_char(p_at at time zone 'America/New_York', 'Dy') end
$$;

-- Supplier deadlines (same rules as the app).
create or replace function _sup_next(s suppliers, p_from timestamptz) returns timestamptz language plpgsql stable as $$
declare tz text := 'America/New_York'; lf timestamp := p_from at time zone tz;
        ct time := coalesce(nullif(s.cutoff,''), '14:00')::time; d date; md date; i int; anchor int; last_day int;
begin
  if coalesce(s.schedule,'weekly') = 'weekly' then
    if coalesce(array_length(s.days,1),0) = 0 then return null; end if;
    for i in 0..7 loop
      d := lf::date + i;
      if extract(dow from d)::int = any(s.days) and d + ct > lf then return (d + ct) at time zone tz; end if;
    end loop;
    return null;
  elsif s.schedule = 'daily' then
    if lf::date + ct > lf then return (lf::date + ct) at time zone tz; end if;
    return (lf::date + 1 + ct) at time zone tz;
  end if;
  if s.start_date is null then return null; end if;
  if s.schedule = 'once' then
    return case when s.start_date + ct > lf then (s.start_date + ct) at time zone tz end;
  elsif s.schedule = 'biweekly' then
    d := s.start_date;
    if d + ct <= lf then d := d + 14 * greatest(0, ((lf::date - d) / 14) - 1); end if;
    for i in 1..60 loop exit when d + ct > lf; d := d + 14; end loop;
    return (d + ct) at time zone tz;
  elsif s.schedule = 'monthly' then
    anchor := extract(day from s.start_date)::int;
    md := date_trunc('month', greatest(s.start_date, (lf::date - interval '1 month')::date))::date;
    for i in 0..40 loop
      last_day := extract(day from (md + interval '1 month' - interval '1 day'))::int;
      d := md + least(anchor, last_day) - 1;
      if d >= s.start_date and d + ct > lf then return (d + ct) at time zone tz; end if;
      md := (md + interval '1 month')::date;
    end loop;
  end if;
  return null;
end $$;

create or replace function _sup_prev(s suppliers, p_from timestamptz) returns timestamptz language plpgsql stable as $$
declare tz text := 'America/New_York'; lf timestamp := p_from at time zone tz;
        ct time := coalesce(nullif(s.cutoff,''), '14:00')::time; d date; i int; first timestamp; nl timestamp; pv timestamp; pd date; last_day int;
begin
  if coalesce(s.schedule,'weekly') = 'weekly' then
    if coalesce(array_length(s.days,1),0) = 0 then return null; end if;
    for i in 0..7 loop
      d := lf::date - i;
      if extract(dow from d)::int = any(s.days) and d + ct <= lf then return (d + ct) at time zone tz; end if;
    end loop;
    return null;
  elsif s.schedule = 'daily' then
    if lf::date + ct <= lf then return (lf::date + ct) at time zone tz; end if;
    return (lf::date - 1 + ct) at time zone tz;
  end if;
  if s.start_date is null then return null; end if;
  first := s.start_date + ct;
  if first > lf then return null; end if;
  if s.schedule = 'once' then return first at time zone tz; end if;
  nl := _sup_next(s, p_from) at time zone tz;
  if nl is null then return null; end if;
  if s.schedule = 'biweekly' then pv := nl - interval '14 days';
  else
    pd := (date_trunc('month', nl::date) - interval '1 month')::date;
    last_day := extract(day from (pd + interval '1 month' - interval '1 day'))::int;
    pv := (pd + least(extract(day from s.start_date)::int, last_day) - 1) + ct;
  end if;
  return case when pv >= first then pv at time zone tz end;
end $$;

-- Has the order for the next deadline been placed? An order right after a cutoff counts as late for the round
-- that just closed; it only covers the next deadline once it's in the second half of the round.
create or replace function _sup_ordered(s suppliers, p_now timestamptz) returns boolean language plpgsql stable as $$
declare pv timestamptz; nx timestamptz;
begin
  if s.last_ordered_at is null then return false; end if;
  if s.schedule = 'once' then return s.schedule_set_at is null or s.last_ordered_at >= s.schedule_set_at; end if;
  pv := _sup_prev(s, p_now); nx := _sup_next(s, p_now);
  if pv is not null and (s.schedule_set_at is null or pv > s.schedule_set_at) then
    return s.last_ordered_at > case when nx is null then pv else pv + (nx - pv) / 2 end;
  end if;
  return s.schedule_set_at is not null and s.last_ordered_at > s.schedule_set_at;
end $$;

-- Everything that should be sent right now, one entry per phone. Marks each item as sent.
create or replace function _push_collect(p_now timestamptz default now()) returns jsonb language plpgsql
set search_path = public, extensions as $$
declare tz text := 'America/New_York'; lnow timestamp := p_now at time zone tz; tnow time := lnow::time;
        today date := _shift_day_at(p_now); covered date;
        sub record; p jsonb; out jsonb := '[]'; tag text; k text; rc int;
        sup suppliers; nx timestamptz; n_low int;
        r record; ov_title text[]; ov_body text[]; os_title text[]; os_body text[];
        total int; done_n int; missed text[]; n_over int; n_out int; body text; st time; due_now boolean;
        endpoint_key text; quiet boolean; sw text[]; cv text[]; mgr boolean; nt text[]; nt_star boolean; nt_party int;
        cs text[]; n_short int; cash_line text; sa text[]; sa_direct boolean; td text[];
begin
  delete from push_sent where sent_at < p_now - interval '45 days';
  -- everyone who turned notifications on gets coverage alerts; the rest is for managers
  for sub in select ps.*, stf.roles as sroles, stf.name as sname from push_subs ps join staff stf on stf.id = ps.staff_id
              where exists (select 1 from logins l where l.staff_id = stf.id) loop
    p := _push_prefs(sub.prefs);
    mgr := _is_manager(sub.sroles);
    quiet := _push_quiet(p, tnow);   -- quiet hours hold back alerts, but not the recap (its time is picked on purpose)
    endpoint_key := md5(sub.endpoint);

    -- 1. order deadlines coming up that haven't been ordered
    if mgr and (p->>'orders')::boolean and not quiet then
      for sup in select * from suppliers order by name loop
        nx := _sup_next(sup, p_now);
        continue when nx is null or nx - make_interval(hours => (p->>'lead_hours')::int) > p_now or _sup_ordered(sup, p_now);
        k := 'order:' || endpoint_key || ':' || sup.id || ':' || extract(epoch from nx)::bigint;
        insert into push_sent(key) values (k) on conflict do nothing; get diagnostics rc = row_count;
        continue when rc = 0;
        select count(*) into n_low from items i join counts c on c.item_id = i.id join invcats ic on ic.id = i.cat_id
         where coalesce(i.supplier_id, ic.supplier_id) = sup.id and i.par is not null and c.on_hand < i.par;
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', 'Order due: ' || sup.name,
          'body', 'Order by ' || _fmt_due(nx, p_now) || '. ' ||
                  case n_low when 0 then 'Nothing below par right now.' when 1 then '1 item below par.' else n_low || ' items below par.' end,
          'url', './#inventory', 'tag', 'order-' || sup.id);
      end loop;
    end if;

    -- 2. overdue tasks (daily tasks only count when they have a due time)
    if mgr and (p->>'overdue')::boolean and not quiet then
      ov_title := '{}'; ov_body := '{}';
      for r in
        select x.* from (
          select tk.id, tk.text, coalesce(ro.name, 'Everyone') as rname, tk.important,
                 case when tk.repeat = 'daily' then today else tk.due_date end as occ,
                 _deadline(case when tk.repeat = 'daily' then today else tk.due_date end, tk.due_time) as dl
            from tasks tk left join roles ro on ro.id = tk.role_id
           where (tk.repeat = 'daily' and tk.due_time is not null and tk.done_day is distinct from today)
              or (tk.repeat in ('weekly','biweekly','monthly') and tk.due_date is not null and (tk.done_until is null or tk.done_until <= p_now))
              or (tk.repeat = 'once' and tk.due_date is not null and not tk.done)) x
         where x.dl < p_now order by x.important desc, x.dl
      loop
        k := 'overdue:' || endpoint_key || ':' || r.id || ':' || r.occ;
        insert into push_sent(key) values (k) on conflict do nothing; get diagnostics rc = row_count;
        continue when rc = 0;
        ov_title := ov_title || (case when r.important then '★ ' else '' end || r.text);
        ov_body := ov_body || (r.rname || ' · was due ' || _fmt_due(r.dl, p_now));
      end loop;
      if array_length(ov_title, 1) = 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', 'Overdue: ' || ov_title[1], 'body', ov_body[1], 'url', './', 'tag', 'overdue');
      elsif array_length(ov_title, 1) > 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', array_length(ov_title, 1) || ' tasks overdue',
          'body', array_to_string(ov_title[1:4], ', ') || case when array_length(ov_title,1) > 4 then ' and ' || (array_length(ov_title,1) - 4) || ' more' else '' end,
          'url', './', 'tag', 'overdue');
      end if;
    end if;

    -- 3. items counted at zero (counted in the last day, after this phone turned notifications on)
    if mgr and (p->>'out')::boolean and not quiet then
      os_title := '{}'; os_body := '{}';
      for r in select i.id, i.name, c.counted_by_name, c.counted_at from counts c join items i on i.id = c.item_id
                where c.on_hand <= 0 and coalesce(i.par, 0) > 0 and c.counted_at > p_now - interval '24 hours'
                  and c.counted_at > sub.created_at - interval '1 hour' order by c.counted_at loop
        k := 'out:' || endpoint_key || ':' || r.id || ':' || extract(epoch from r.counted_at)::bigint;
        insert into push_sent(key) values (k) on conflict do nothing; get diagnostics rc = row_count;
        continue when rc = 0;
        os_title := os_title || r.name;
        os_body := os_body || ('Counted at 0 by ' || coalesce(r.counted_by_name, 'someone') || ' · ' || to_char(r.counted_at at time zone tz, 'FMHH12:MI AM'));
      end loop;
      if array_length(os_title, 1) = 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', 'Out of ' || os_title[1], 'body', os_body[1], 'url', './#inventory', 'tag', 'out');
      elsif array_length(os_title, 1) > 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', array_length(os_title, 1) || ' items out',
          'body', array_to_string(os_title[1:5], ', ') || case when array_length(os_title,1) > 5 then ' and more' else '' end,
          'url', './#inventory', 'tag', 'out');
      end if;
    end if;

    -- 6. shifts that need coverage: staff hear about the ones they could work, managers about all of them
    if (p->>'coverage')::boolean and not quiet then
      cv := '{}';
      for r in select s.id, s.start_at, s.end_at, s.role_id, s.posted_at, s.posted_note, o.name as owner
                 from shifts s left join staff o on o.id = s.staff_id
                where s.up_for_grabs and s.start_at > p_now and s.posted_at > p_now - interval '14 days'
                  and s.posted_at > sub.created_at - interval '1 hour'
                  and s.staff_id is distinct from sub.staff_id and s.posted_by is distinct from sub.staff_id
                  and (mgr or ((s.role_id is null or s.role_id = any(sub.sroles))
                               and not exists (select 1 from shifts x where x.staff_id = sub.staff_id
                                                  and x.start_at < _shift_end(s.start_at, s.end_at) and _shift_end(x.start_at, x.end_at) > s.start_at)))
                order by s.start_at loop
        k := 'cover:' || endpoint_key || ':' || r.id || ':' || (extract(epoch from r.posted_at) * 1000)::bigint;
        insert into push_sent(key) values (k) on conflict do nothing; get diagnostics rc = row_count;
        continue when rc = 0;
        cv := cv || (coalesce(r.owner || ' needs someone for ', 'Open shift: ') || _fmt_shift_role(r.start_at, r.end_at, r.role_id) ||
                     case when coalesce(r.posted_note, '') <> '' then '. “' || r.posted_note || '”' else '' end);
      end loop;
      if array_length(cv, 1) = 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', 'Shift needs coverage', 'body', cv[1], 'url', './#schedule', 'tag', 'cover');
      elsif array_length(cv, 1) > 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', array_length(cv, 1) || ' shifts need coverage', 'body', array_to_string(cv[1:3], '. ') || case when array_length(cv,1) > 3 then '…' else '' end,
          'url', './#schedule', 'tag', 'cover');
      end if;
    end if;

    -- 5. someone covered a shift: tell the person covered, managers, and everyone who was alerted about it
    if (p->>'swaps')::boolean and not quiet then
      sw := '{}';
      for r in select w.id, w.from_staff, w.from_name, w.to_name, w.start_at, w.end_at, w.role_id from shift_swaps w
                where w.at > p_now - interval '24 hours' and w.at > sub.created_at - interval '1 hour'
                  and w.to_staff is distinct from sub.staff_id
                  and (mgr or w.from_staff = sub.staff_id
                       or exists (select 1 from push_sent ps where ps.key like 'cover:' || endpoint_key || ':' || w.shift_id || ':%'))
                order by w.at loop
        k := 'swap:' || endpoint_key || ':' || r.id;
        insert into push_sent(key) values (k) on conflict do nothing; get diagnostics rc = row_count;
        continue when rc = 0;
        sw := sw || (r.to_name || ' is covering ' ||
                     case when r.from_staff = sub.staff_id then 'your shift ' when r.from_staff is null then 'the open shift ' else r.from_name || '''s shift ' end ||
                     _fmt_shift_role(r.start_at, r.end_at, r.role_id));
      end loop;
      if array_length(sw, 1) = 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', 'Shift covered', 'body', sw[1], 'url', './#schedule', 'tag', 'swap');
      elsif array_length(sw, 1) > 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', array_length(sw, 1) || ' shifts covered', 'body', array_to_string(sw[1:3], '. ') || case when array_length(sw,1) > 3 then '…' else '' end,
          'url', './#schedule', 'tag', 'swap');
      end if;
    end if;

    -- 7. new tasks for this person: assigned to them, for one of their roles, or for everyone (not ones they added)
    if (p->>'tasks')::boolean and not quiet then
      nt := '{}'; nt_star := false; nt_party := 0;
      for r in select tk.id, tk.text, tk.important, tk.repeat, tk.due_date, tk.due_time, tk.assignee, tk.party_step from tasks tk
                where tk.added_at > p_now - interval '24 hours' and tk.added_at > sub.created_at - interval '1 hour'
                  and tk.added_by is distinct from sub.staff_id and not tk.done
                  and case when tk.assignee is not null then tk.assignee = sub.staff_id
                           when tk.role_id is not null then tk.role_id = any(sub.sroles)
                           else true end
                order by tk.important desc, tk.added_at loop
        k := 'task:' || endpoint_key || ':' || r.id;
        insert into push_sent(key) values (k) on conflict do nothing; get diagnostics rc = row_count;
        continue when rc = 0;
        nt_star := nt_star or r.important;
        if r.party_step = 'reply' then   -- a new party inquiry
          nt_party := nt_party + 1;
          nt := nt || substr(r.text, length('Reply to party inquiry: ') + 1);
          continue;
        end if;
        nt := nt || (case when r.important then '★ ' else '' end || r.text ||
                     case when r.repeat = 'daily' then ' · every day'
                          when r.due_date is not null and r.due_time is not null then ' · due ' || _fmt_due(_deadline(r.due_date, r.due_time), p_now)
                          when r.due_date is not null then ' · due ' || case r.due_date - today when 0 then 'today' when 1 then 'tomorrow'
                                                                         else to_char(r.due_date, 'Dy Mon FMDD') end
                          else '' end ||
                     case when r.assignee = sub.staff_id then ' · for you' else '' end);
      end loop;
      if array_length(nt, 1) = 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', case when nt_party > 0 then 'New party inquiry' when nt_star then 'New important task' else 'New task' end, 'body', nt[1],
          'url', case when nt_party > 0 then './#events' else './' end, 'tag', 'task');
      elsif array_length(nt, 1) > 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', array_length(nt, 1) || case when nt_party = array_length(nt, 1) then ' new party inquiries' else ' new tasks' end,
          'body', array_to_string(nt[1:3], '. ') || case when array_length(nt,1) > 3 then '…' else '' end,
          'url', case when nt_party = array_length(nt, 1) then './#events' else './' end, 'tag', 'task');
      end if;
    end if;

    -- 11. daily cash, to the others on the cash book list (Aidan, Tom, Mandy) only
    if _can_cash_book(sub.staff_id) and (p->>'cashbook')::boolean and not quiet then
      for r in select dc.* from daily_cash dc
                where dc.at > p_now - interval '24 hours' and dc.at > sub.created_at - interval '1 hour'
                  and dc.by_id is distinct from sub.staff_id order by dc.day loop
        k := 'dcash:' || endpoint_key || ':' || r.day || ':' || r.edits;
        insert into push_sent(key) values (k) on conflict do nothing; get diagnostics rc = row_count;
        continue when rc = 0;
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', case when r.edits > 0 then 'Daily cash updated · ' else 'Daily cash · ' end || to_char(r.day, 'Dy Mon FMDD'),
          'body', 'Sales ' || _money(r.cash_sales) || ' · Payouts ' || _money(r.payouts_total) ||
                  ' · COH ' || case when r.left_over < 0 then '−' else '' end || _money(r.left_over) ||
                  coalesce(' (' || (select string_agg((x->>'who') || ' ' || _money((x->>'amount')::numeric), ', ') from jsonb_array_elements(r.payouts) x) || ')', '') ||
                  ' · ' || coalesce(r.by_name, ''),
          'url', './#dailycash', 'tag', 'dcash');
      end loop;
    end if;

    -- 10. alerts from staff: to this manager by name (even in quiet hours), or to any manager
    if mgr and (p->>'staff')::boolean then
      sa := '{}'; sa_direct := false;
      for r in select a.* from manager_alerts a
                where a.handled_at is null and a.at > p_now - interval '24 hours' and a.at > sub.created_at - interval '1 hour'
                  and a.from_id is distinct from sub.staff_id
                  and (a.to_staff = sub.staff_id or (a.to_staff is null and not quiet))
                order by a.at loop
        k := 'staff:' || endpoint_key || ':' || r.id;
        insert into push_sent(key) values (k) on conflict do nothing; get diagnostics rc = row_count;
        continue when rc = 0;
        sa_direct := sa_direct or r.to_staff = sub.staff_id;
        sa := sa || (r.from_name || ' · ' || case r.area when 'foh' then 'FOH' else 'BOH' end || ': ' || left(r.text, 140));
      end loop;
      if array_length(sa, 1) = 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', case when sa_direct then 'Alert for you' else 'Alert for a manager' end, 'body', sa[1], 'url', './#alerts', 'tag', 'staff');
      elsif array_length(sa, 1) > 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', array_length(sa, 1) || ' alerts from staff', 'body', array_to_string(sa[1:3], '. ') || case when array_length(sa,1) > 3 then '…' else '' end,
          'url', './#alerts', 'tag', 'staff');
      end if;
    end if;

    -- 12. a task this manager added got checked off by someone else: what, and who did it
    if mgr and (p->>'done')::boolean and not quiet then
      td := '{}';
      for r in select tk.id, tk.text, tk.done_by_name, tk.done_at from tasks tk
                where tk.added_by = sub.staff_id and tk.done and tk.done_at is not null
                  and tk.done_at > p_now - interval '12 hours' and tk.done_at > sub.created_at
                  and tk.done_by is distinct from sub.staff_id
                order by tk.done_at loop
        k := 'done:' || endpoint_key || ':' || r.id || ':' || extract(epoch from r.done_at)::bigint;   -- each time a repeating task is done
        insert into push_sent(key) values (k) on conflict do nothing; get diagnostics rc = row_count;
        continue when rc = 0;
        td := td || (coalesce(r.done_by_name, 'Someone') || ' checked off “' || left(r.text, 120) || '”');
      end loop;
      if array_length(td, 1) = 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', 'Task done ✓', 'body', td[1], 'url', './', 'tag', 'done');
      elsif array_length(td, 1) > 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', array_length(td, 1) || ' of your tasks done ✓', 'body', array_to_string(td[1:3], '. ') || case when array_length(td,1) > 3 then '…' else '' end,
          'url', './', 'tag', 'done');
      end if;
    end if;

    -- 8. a drawer that came up short (changing it sends a new alert if it's still short)
    if mgr and (p->>'cash')::boolean and not quiet then
      cs := '{}'; n_short := 0;
      for r in select c.id, c.drawer_name, c.short_amt, c.by_name, c.at, c.note from cashouts c
                where c.at > p_now - interval '24 hours' and c.at > sub.created_at - interval '1 hour' and c.short_amt > 0
                  and c.by_id is distinct from sub.staff_id
                order by c.at loop
        k := 'cash:' || endpoint_key || ':' || r.id || ':' || extract(epoch from r.at)::bigint;
        insert into push_sent(key) values (k) on conflict do nothing; get diagnostics rc = row_count;
        continue when rc = 0;
        n_short := n_short + 1;
        cs := cs || (r.drawer_name || ' drawer short ' || _money(r.short_amt) || ' · ' || coalesce(r.by_name, 'someone') ||
                     case when r.note <> '' then '. “' || left(r.note, 80) || '”' else '' end);
      end loop;
      if array_length(cs, 1) = 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', 'Drawer short', 'body', cs[1], 'url', './#cash', 'tag', 'cash');
      elsif array_length(cs, 1) > 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', array_length(cs, 1) || ' drawers short', 'body', array_to_string(cs, '. '), 'url', './#cash', 'tag', 'cash');
      end if;
    end if;

    -- 4. nightly recap of a finished shift day
    if mgr and (p->>'summary')::boolean then
      st := (p->>'summary_time')::time;
      covered := (lnow - interval '5 hours')::date;
      if tnow >= time '05:00' then covered := covered - 1; end if;
      -- sent at the chosen time the morning after the shift day ends (or that night, for times before 5 AM); up to 3 hours late if a check is missed
      due_now := lnow >= (covered + 1) + st and lnow < (covered + 1) + st + interval '3 hours';
      if due_now then
        k := 'summary:' || endpoint_key || ':' || covered;
        insert into push_sent(key) values (k) on conflict do nothing; get diagnostics rc = row_count;
        if rc > 0 then
          -- tasks checked off during that shift day (still checked off at the end of it)
          with last_ev as (
            select distinct on (text, place) text, place, kind from log
             where day = covered and kind in ('done','undone') order by text, place, at desc)
          select count(*) filter (where kind = 'done') into done_n from last_ev;
          select coalesce(array_agg(case when tk.important then '★ ' else '' end || tk.text order by tk.important desc, _deadline(tk.due_date, tk.due_time)), '{}'), count(*)
            into missed, n_over from tasks tk
           where ((tk.repeat in ('weekly','biweekly','monthly') and (tk.done_until is null or tk.done_until <= p_now))
                  or (tk.repeat = 'once' and not tk.done))
             and tk.due_date is not null and _deadline(tk.due_date, tk.due_time) < p_now;
          select count(*) into n_out from counts c join items i on i.id = c.item_id where c.on_hand <= 0 and coalesce(i.par, 0) > 0;
          -- cash: any drawer short (only once there are drawers)
          select case when count(*) = 0 then null
                      when count(*) filter (where short_amt > 0) = 0 then 'No drawers short.'
                      else 'Drawer short: ' || string_agg(drawer_name || ' ' || _money(short_amt), ', ' order by drawer_name) filter (where short_amt > 0) || '.' end
            into cash_line from cashouts where day = covered;
          if cash_line is null and exists (select 1 from drawers where active) then cash_line := 'No cash-out entered.'; end if;
          total := done_n + n_over + n_out + case when cash_line is null then 0 else 1 end;
          if total > 0 then
            body := case done_n when 0 then 'No tasks checked off.' when 1 then '1 task checked off.' else done_n || ' tasks checked off.' end;
            if n_over > 0 then
              body := body || ' Overdue: ' || array_to_string(missed[1:3], ', ') ||
                      case when n_over > 3 then ' and ' || (n_over - 3) || ' more' else '' end || '.';
            end if;
            if n_out > 0 then body := body || ' ' || n_out || case when n_out = 1 then ' item' else ' items' end || ' out.'; end if;
            if cash_line is not null then body := body || ' ' || cash_line; end if;
            out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
              'title', 'Shift recap · ' || to_char(covered, 'Dy Mon FMDD'), 'body', body, 'url', './', 'tag', 'recap');
          end if;
        end if;
      end if;
    end if;
  end loop;
  return out;
end $$;

-- Phones the push service says no longer exist.
create or replace function _push_forget(p_endpoints text[]) returns void language sql as $$
  delete from push_subs where endpoint = any(p_endpoints)
$$;

-- "Send a test" from the settings screen: only to the logged-in manager's own phone.
create or replace function _push_test(p_token uuid, p_endpoint text) returns jsonb language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); s push_subs;
begin
  select * into s from push_subs where endpoint = p_endpoint and staff_id = me.id;
  if not found then return null; end if;
  return jsonb_build_object('endpoint', s.endpoint, 'p256dh', s.p256dh, 'auth', s.auth,
    'title', 'Notifications are on', 'body', 'This is how Brewskis alerts will look on this phone, ' || me.name || '.', 'url', './', 'tag', 'test');
end $$;

create or replace function api_push_save(p_token uuid, p_endpoint text, p_p256dh text, p_auth text, p_prefs jsonb) returns jsonb language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); pr jsonb := _push_prefs(p_prefs);
begin
  if coalesce(p_endpoint,'') !~ '^https://' or coalesce(p_p256dh,'') = '' or coalesce(p_auth,'') = '' then raise exception 'bad_subscription'; end if;
  insert into push_subs (endpoint, staff_id, p256dh, auth, prefs) values (p_endpoint, me.id, p_p256dh, p_auth, pr)
  on conflict (endpoint) do update set staff_id = me.id, p256dh = excluded.p256dh, auth = excluded.auth, prefs = excluded.prefs, updated_at = now();
  return pr;
end $$;

create or replace function api_push_get(p_token uuid, p_endpoint text) returns jsonb language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); pr jsonb;
begin
  select prefs into pr from push_subs where endpoint = p_endpoint and staff_id = me.id;
  return case when found then _push_prefs(pr) end;
end $$;

create or replace function api_push_remove(p_token uuid, p_endpoint text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token);
begin delete from push_subs where endpoint = p_endpoint and staff_id = me.id; end $$;

-- ---------- app versions (added Oct 2026) ----------
-- Each phone or computer reports which version of the app it's running when it opens and every few minutes after.
-- Managers see this on the Team tab to spot anyone who hasn't picked up the latest update.
create table if not exists app_devices (
  device_id text not null,
  staff_id text not null references staff(id) on delete cascade,
  version int not null,
  platform text not null default '',
  seen_at timestamptz not null default now(),
  primary key (device_id, staff_id)
);
do $$
begin
  alter table app_devices enable row level security;
  revoke all on table app_devices from public;
  if exists (select 1 from pg_roles where rolname='anon') then revoke all on table app_devices from anon; end if;
  if exists (select 1 from pg_roles where rolname='authenticated') then revoke all on table app_devices from authenticated; end if;
end $$;

create or replace function api_hello(p_token uuid, p_device text, p_version int, p_platform text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token);
begin
  if coalesce(p_device,'') !~ '^[A-Za-z0-9-]{8,64}$' or p_version is null then return; end if;
  insert into app_devices (device_id, staff_id, version, platform, seen_at)
  values (p_device, me.id, p_version, left(coalesce(p_platform,''), 40), now())
  on conflict (device_id, staff_id) do update set version = excluded.version, platform = excluded.platform, seen_at = now()
   where app_devices.version is distinct from excluded.version or app_devices.seen_at < now() - interval '5 minutes';
  delete from app_devices where seen_at < now() - interval '60 days';
end $$;

create or replace function api_versions(p_token uuid) returns json language plpgsql stable
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  return coalesce((select json_agg(json_build_object('staff_id', staff_id, 'device_id', device_id, 'version', version,
                                                     'platform', platform, 'seen_at', seen_at) order by seen_at desc)
                     from app_devices), '[]');
end $$;

-- ---------- default supplier for a whole list (added Oct 2026) ----------
-- An item with no supplier of its own is ordered from its list's default supplier (e.g. Liquor -> PLCB).
alter table invcats add column if not exists supplier_id text references suppliers(id) on delete set null;

create or replace function api_set_category_supplier(p_token uuid, p_cat_id text, p_supplier_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  update invcats set supplier_id = (select id from suppliers where id = nullif(p_supplier_id,'')) where id = p_cat_id;
  if not found then raise exception 'not_found'; end if;
end $$;

-- ---------- on tap board (added Oct 2026) ----------
-- Staff mark kegs as on tap or kicked; managers can set the name and style customers see.
-- api_on_tap() needs no login: it powers the public board (taps.html) and only returns what's on tap.
alter table items add column if not exists on_tap boolean not null default false;
alter table items add column if not exists tapped_at timestamptz;
alter table items add column if not exists tap_label text not null default '';
alter table items add column if not exists tap_note text not null default '';

create or replace function api_set_on_tap(p_token uuid, p_item_id text, p_on boolean) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); it items;
begin
  select * into it from items where id = p_item_id for update;
  if not found then raise exception 'not_found'; end if;
  if coalesce(p_on, false) = it.on_tap then return; end if;
  update items set on_tap = coalesce(p_on, false), tapped_at = case when p_on then now() else tapped_at end where id = p_item_id;
  perform _log(me, case when p_on then 'tapped' else 'kicked' end, coalesce(nullif(it.tap_label,''), it.name), 'Inventory');
end $$;

create or replace function api_set_tap_info(p_token uuid, p_item_id text, p_label text, p_note text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  update items set tap_label = left(coalesce(trim(p_label),''), 60), tap_note = left(coalesce(trim(p_note),''), 80) where id = p_item_id;
  if not found then raise exception 'not_found'; end if;
end $$;

create or replace function api_on_tap() returns json language sql stable
set search_path = public, extensions as $$
  select json_build_object(
    'updated_at', now(),
    'taps', coalesce((select json_agg(json_build_object(
              'name', coalesce(nullif(tap_label,''), trim(regexp_replace(name, '\s+(1/2|1/4|1/6|50L|30L|20L|sixtel|half|keg)$', '', 'i'))),
              'note', tap_note,
              'tapped_at', tapped_at) order by coalesce(nullif(tap_label,''), name))
            from items where on_tap), '[]'))
$$;

-- ---------- schedule and shift swaps (added Oct 2026) ----------
-- Managers build the schedule. Anyone can give away one of their upcoming shifts; a coworker with that role
-- takes it and it's theirs right away (managers get a notification). Each person gets a private calendar link
-- (staff.cal_token) that the "calendar" Edge Function turns into a Google/Apple Calendar subscription.
create table if not exists shifts (
  id text primary key default gen_random_uuid()::text,
  staff_id text references staff(id) on delete set null,      -- null = open shift anyone with the role can take
  role_id text references roles(id) on delete set null,
  start_at timestamptz not null,
  end_at timestamptz,                                          -- null = until close
  note text not null default '',
  up_for_grabs boolean not null default false,
  posted_at timestamptz,
  posted_note text not null default '',
  created_at timestamptz not null default now()
);
create index if not exists shifts_start_idx on shifts (start_at);
create table if not exists shift_swaps (
  id bigserial primary key,
  at timestamptz not null default now(),
  shift_id text, role_id text,
  from_staff text, from_name text,
  to_staff text, to_name text,
  start_at timestamptz, end_at timestamptz
);
alter table staff add column if not exists cal_token uuid not null default gen_random_uuid();
create unique index if not exists staff_cal_token_idx on staff (cal_token);
-- v21: who put a shift up for coverage, and who created it (staff can add a shift that wasn't on the schedule when asking for coverage)
alter table shifts add column if not exists posted_by text;
alter table shifts add column if not exists created_by text;

do $$
declare t text;
begin
  foreach t in array array['shifts','shift_swaps'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on table %I from public', t);
    if exists (select 1 from pg_roles where rolname='anon') then execute format('revoke all on table %I from anon', t); end if;
    if exists (select 1 from pg_roles where rolname='authenticated') then execute format('revoke all on table %I from authenticated', t); end if;
  end loop;
  if exists (select 1 from pg_roles where rolname='anon') then revoke all on sequence shift_swaps_id_seq from anon; end if;
  if exists (select 1 from pg_roles where rolname='authenticated') then revoke all on sequence shift_swaps_id_seq from authenticated; end if;
end $$;

-- "Until close" means 2 AM (Pennsylvania last call) after the shift starts.
create or replace function _close_at(p_start timestamptz) returns timestamptz language sql stable as $$
  select (((p_start at time zone 'America/New_York')::date
           + case when (p_start at time zone 'America/New_York')::time < time '05:00' then 0 else 1 end) + time '02:00')
         at time zone 'America/New_York'
$$;
create or replace function _shift_end(p_start timestamptz, p_end timestamptz) returns timestamptz language sql stable as $$
  select coalesce(p_end, _close_at(p_start))
$$;
-- "Fri Oct 31, 5:00 PM–close"
create or replace function _fmt_shift(p_start timestamptz, p_end timestamptz) returns text language sql stable as $$
  select to_char(p_start at time zone 'America/New_York', 'Dy Mon FMDD, FMHH12:MI AM') || '–' ||
         case when p_end is null then 'close' else to_char(p_end at time zone 'America/New_York', 'FMHH12:MI AM') end
$$;
create or replace function _shift_json(s shifts) returns json language sql stable as $$
  select json_build_object('id', s.id, 'staff_id', s.staff_id, 'role_id', s.role_id, 'start_at', s.start_at, 'end_at', s.end_at,
                           'note', s.note, 'up_for_grabs', s.up_for_grabs, 'posted_at', s.posted_at, 'posted_note', s.posted_note,
                           'posted_by', s.posted_by, 'created_by', s.created_by)
$$;

-- Send notifications right away instead of waiting for the 15-minute check (coverage can't wait).
-- Asks the "notify" Edge Function to run now; never lets a hiccup here break the action that called it.
create or replace function _push_kick() returns void language plpgsql
set search_path = public, extensions as $$
begin
  if to_regnamespace('net') is null then return; end if;
  execute $q$select net.http_post(
    url := 'https://xlvukvolpmsgyhtvbtut.supabase.co/functions/v1/notify',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-cron-secret', (select value from public.app_secrets where name = 'cron_secret')),
    body := '{}'::jsonb, timeout_milliseconds := 30000)$q$;
exception when others then null;
end $$;

-- "Mon Nov 2, 5:00 PM–close (Closing bartender)"
create or replace function _fmt_shift_role(p_start timestamptz, p_end timestamptz, p_role text) returns text language sql stable as $$
  select _fmt_shift(p_start, p_end) || coalesce(' (' || (select name from roles where id = p_role) || ')', '')
$$;

create or replace function api_schedule(p_token uuid, p_from date, p_to date) returns json language plpgsql stable
set search_path = public, extensions as $$
declare me staff := _me(p_token);
begin
  if p_to - p_from > 62 then p_to := p_from + 62; end if;
  return coalesce((select json_agg(_shift_json(s) order by s.start_at) from shifts s
                    where (s.start_at at time zone 'America/New_York')::date between p_from and p_to), '[]');
end $$;

create or replace function api_save_shift(p_token uuid, p_id text, p_staff_id text, p_role_id text, p_date date,
                                          p_start text, p_end text, p_note text) returns text language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); tz text := 'America/New_York'; st timestamp; en timestamp; sid text; rid text; old shifts; new_id text;
begin
  if p_date is null or coalesce(p_start,'') !~ '^\d{1,2}:\d{2}' then raise exception 'bad_time'; end if;
  st := p_date + p_start::time;
  if coalesce(p_end,'') ~ '^\d{1,2}:\d{2}' then
    en := p_date + p_end::time;
    if en <= st then en := en + interval '1 day'; end if;
    if en - st > interval '20 hours' then raise exception 'bad_time'; end if;
  end if;
  select id into sid from staff where id = nullif(p_staff_id,'');
  select id into rid from roles where id = nullif(p_role_id,'');
  if p_id is null or p_id = '' then
    insert into shifts (staff_id, role_id, start_at, end_at, note, up_for_grabs, posted_at, posted_by, created_by)
    values (sid, rid, st at time zone tz, en at time zone tz, left(coalesce(trim(p_note),''),120), sid is null, case when sid is null then now() end,
            case when sid is null then me.id end, me.id)
    returning id into new_id;
    if sid is null and st at time zone tz > now() then perform _push_kick(); end if;   -- an open shift: tell the people who can work it
    return new_id;
  end if;
  select * into old from shifts where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  update shifts set staff_id = sid, role_id = rid, start_at = st at time zone tz, end_at = en at time zone tz,
                    note = left(coalesce(trim(p_note),''),120),
                    up_for_grabs = case when sid is null then true when sid is distinct from old.staff_id then false else up_for_grabs end,
                    posted_at = case when sid is null and old.staff_id is not null then now() when sid is distinct from old.staff_id then null else posted_at end,
                    posted_note = case when sid is distinct from old.staff_id then '' else posted_note end,
                    posted_by = case when sid is null and old.staff_id is not null then me.id when sid is distinct from old.staff_id then null else posted_by end
   where id = p_id;
  if sid is null and old.staff_id is not null and st at time zone tz > now() then perform _push_kick(); end if;
  return p_id;
end $$;

-- Managers can delete any shift. Staff can remove a shift they added themselves when asking for coverage.
create or replace function api_delete_shift(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); s shifts;
begin
  select * into s from shifts where id = p_id;
  if not found then return; end if;
  if not _is_manager(me.roles) and not (s.created_by = me.id and s.staff_id = me.id) then raise exception 'managers_only'; end if;
  delete from shifts where id = p_id;
end $$;

-- Copy every shift from one week (starting p_from) into another (starting p_to). Skips shifts already there.
create or replace function api_copy_week(p_token uuid, p_from date, p_to date) returns int language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); tz text := 'America/New_York'; n int;
begin
  insert into shifts (staff_id, role_id, start_at, end_at, note, up_for_grabs, posted_at, posted_by, created_by)
  select s.staff_id, s.role_id,
         ((s.start_at at time zone tz) + make_interval(days => p_to - p_from)) at time zone tz,
         ((s.end_at at time zone tz) + make_interval(days => p_to - p_from)) at time zone tz,
         s.note, s.staff_id is null, case when s.staff_id is null then now() end, case when s.staff_id is null then me.id end, me.id
    from shifts s
   where (s.start_at at time zone tz)::date between p_from and p_from + 6
     and not exists (select 1 from shifts x
                      where x.staff_id is not distinct from s.staff_id and x.role_id is not distinct from s.role_id
                        and x.start_at = ((s.start_at at time zone tz) + make_interval(days => p_to - p_from)) at time zone tz);
  get diagnostics n = row_count;
  if n > 0 then perform _push_kick(); end if;
  return n;
end $$;

-- Ask for coverage on one of your upcoming shifts (managers can do it for anyone). It stays yours until someone covers it.
create or replace function api_post_shift(p_token uuid, p_id text, p_note text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); s shifts; owner text;
begin
  select * into s from shifts where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if s.staff_id is distinct from me.id and not _is_manager(me.roles) then raise exception 'managers_only'; end if;
  if s.start_at <= now() then raise exception 'shift_started'; end if;
  update shifts set up_for_grabs = true, posted_at = now(), posted_by = me.id, posted_note = left(coalesce(trim(p_note),''),120) where id = p_id;
  select name into owner from staff where id = s.staff_id;
  perform _log(me, 'shift_posted', case when s.staff_id is distinct from me.id then coalesce(owner || '''s shift ', 'an open shift ') else '' end ||
                                   _fmt_shift_role(s.start_at, s.end_at, s.role_id), 'Schedule');
  perform _push_kick();
end $$;

-- Anyone: ask for coverage on a shift by date and time. If you already have a shift then, that one is used;
-- otherwise the shift is added to the schedule as yours and put up for coverage.
create or replace function api_request_cover(p_token uuid, p_role_id text, p_date date, p_start text, p_end text, p_note text) returns text language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); tz text := 'America/New_York'; st timestamptz; en timestamptz; rid text; sid text;
begin
  if p_date is null or coalesce(p_start,'') !~ '^\d{1,2}:\d{2}' then raise exception 'bad_time'; end if;
  st := (p_date + p_start::time) at time zone tz;
  if coalesce(p_end,'') ~ '^\d{1,2}:\d{2}' then
    en := (p_date + p_end::time) at time zone tz;
    if en <= st then en := en + interval '1 day'; end if;
    if en - st > interval '20 hours' then raise exception 'bad_time'; end if;
  end if;
  if st <= now() then raise exception 'shift_started'; end if;
  if st > now() + interval '120 days' then raise exception 'bad_time'; end if;
  select id into rid from roles where id = nullif(p_role_id,'');
  if rid is not null and not (rid = any(me.roles)) and not _is_manager(me.roles) then raise exception 'not_your_role'; end if;
  select id into sid from shifts x where x.staff_id = me.id
     and x.start_at < _shift_end(st, en) and _shift_end(x.start_at, x.end_at) > st order by abs(extract(epoch from x.start_at - st)) limit 1;
  if sid is null then
    insert into shifts (staff_id, role_id, start_at, end_at, created_by) values (me.id, rid, st, en, me.id) returning id into sid;
  end if;
  perform api_post_shift(p_token, sid, p_note);
  return sid;
end $$;

create or replace function api_unpost_shift(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); s shifts;
begin
  select * into s from shifts where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if s.staff_id is null then raise exception 'managers_only'; end if;
  if s.staff_id is distinct from me.id and not _is_manager(me.roles) then raise exception 'managers_only'; end if;
  update shifts set up_for_grabs = false, posted_at = null, posted_note = '' where id = p_id;
end $$;

-- Cover a shift that needs coverage. It's yours right away; the person you're covering, managers,
-- and everyone who was alerted about it get a notification.
create or replace function api_take_shift(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); s shifts; from_name text; rname text;
begin
  select * into s from shifts where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if not s.up_for_grabs or s.staff_id is not distinct from me.id then raise exception 'shift_gone'; end if;
  if s.start_at <= now() then raise exception 'shift_started'; end if;
  if s.role_id is not null and not (s.role_id = any(me.roles)) and not _is_manager(me.roles) then raise exception 'not_your_role'; end if;
  if exists (select 1 from shifts x where x.staff_id = me.id and x.id <> s.id
              and x.start_at < _shift_end(s.start_at, s.end_at) and _shift_end(x.start_at, x.end_at) > s.start_at) then
    raise exception 'overlaps';
  end if;
  select name into from_name from staff where id = s.staff_id;
  select name into rname from roles where id = s.role_id;
  insert into shift_swaps (shift_id, role_id, from_staff, from_name, to_staff, to_name, start_at, end_at)
  values (s.id, s.role_id, s.staff_id, coalesce(from_name, 'Open shift'), me.id, me.name, s.start_at, s.end_at);
  update shifts set staff_id = me.id, up_for_grabs = false, posted_at = null, posted_note = '' where id = p_id;
  perform _log(me, 'shift_taken', coalesce(from_name || '''s shift ', 'an open shift ') || _fmt_shift_role(s.start_at, s.end_at, s.role_id), 'Schedule');
  delete from shift_swaps where at < now() - interval '120 days';
  perform _push_kick();
end $$;

-- Private calendar link for the logged-in person.
create or replace function api_cal_link(p_token uuid) returns json language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token);
begin return json_build_object('token', me.cal_token, 'manager', _is_manager(me.roles)); end $$;

create or replace function api_cal_reset(p_token uuid) returns json language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); t uuid := gen_random_uuid();
begin
  update staff set cal_token = t where id = me.id;
  return json_build_object('token', t, 'manager', _is_manager(me.roles));
end $$;

-- iCalendar text helpers
create or replace function _ics_text(p text) returns text language sql immutable as $$
  select replace(replace(replace(replace(replace(coalesce(p,''), E'\\', E'\\\\'), ';', E'\;'), ',', E'\\,'), E'\r', ''), E'\n', E'\\n')
$$;
create or replace function _ics_fold(p text) returns text language plpgsql immutable as $$
declare out text := ''; rest text := p;
begin
  if length(rest) <= 70 then return rest; end if;
  out := left(rest, 70); rest := substr(rest, 71);
  while length(rest) > 0 loop out := out || E'\r\n ' || left(rest, 69); rest := substr(rest, 70); end loop;
  return out;
end $$;
create or replace function _ics_time(p timestamptz) returns text language sql immutable as $$
  select to_char(p at time zone 'UTC', 'YYYYMMDD"T"HH24MISS"Z"')
$$;

-- The calendar file for a private link. p_all = whole team (managers only).
create or replace function _calendar_ics(p_cal uuid, p_all boolean) returns text language plpgsql stable
set search_path = public, extensions as $$
declare who staff; team boolean; lines text[] := '{}'; r record; summary text; descr text;
begin
  select * into who from staff where cal_token = p_cal;
  if not found then return null; end if;
  team := coalesce(p_all, false) and _is_manager(who.roles);
  lines := array['BEGIN:VCALENDAR', 'VERSION:2.0', 'PRODID:-//JT Brewskis//Staff app//EN', 'CALSCALE:GREGORIAN', 'METHOD:PUBLISH',
                 _ics_fold('X-WR-CALNAME:' || _ics_text(case when team then 'JT Brewski''s team schedule' else 'JT Brewski''s shifts (' || who.name || ')' end)),
                 'X-WR-TIMEZONE:America/New_York', 'REFRESH-INTERVAL;VALUE=DURATION:PT1H', 'X-PUBLISHED-TTL:PT1H'];
  for r in select s.*, st.name as sname, ro.name as rname from shifts s
            left join staff st on st.id = s.staff_id left join roles ro on ro.id = s.role_id
           where s.start_at > now() - interval '60 days' and s.start_at < now() + interval '120 days'
             and (team or s.staff_id = who.id)
           order by s.start_at loop
    summary := case when team then coalesce(r.sname, 'Open shift') || coalesce(' · ' || r.rname, '')
                    else coalesce(r.rname, 'Shift') || ' · JT Brewski''s' end;
    descr := concat_ws(E'\n',
               case when r.end_at is null then 'Until close' end,
               nullif(r.note, ''),
               case when r.up_for_grabs then 'Up for grabs in the app' end);
    lines := lines || array['BEGIN:VEVENT', 'UID:' || r.id || '@jtbrewskis', 'DTSTAMP:' || _ics_time(now()),
                            'DTSTART:' || _ics_time(r.start_at), 'DTEND:' || _ics_time(_shift_end(r.start_at, r.end_at)),
                            _ics_fold('SUMMARY:' || _ics_text(summary)), 'LOCATION:' || _ics_text('JT Brewski''s Pub')];
    if descr <> '' then lines := lines || _ics_fold('DESCRIPTION:' || _ics_text(descr)); end if;
    lines := lines || 'END:VEVENT'::text;
  end loop;
  lines := lines || 'END:VCALENDAR'::text;
  return array_to_string(lines, E'\r\n') || E'\r\n';
end $$;

-- ---------- events (added Oct 2026) ----------
-- The Events tab: a calendar of what's coming up at the pub. Managers add them; everyone sees them.
--   kind: party | entertainment | standard | other
-- Events marked "Promote it" get three "Promote" tasks for managers, due 2 weeks, 1 week and 1 day before.
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
-- v25: Standard events can repeat. day is the first date; the app works out the rest.
--   repeat: none | weekly | biweekly | monthly (same date) | monthly_nth (e.g. 2nd Tuesday) | monthly_last (e.g. last Friday)
--   repeat_until: last date it can happen (null = keeps going); skip_dates: single dates that are called off
alter table events add column if not exists repeat text not null default 'none';
alter table events add column if not exists repeat_until date;
alter table events add column if not exists skip_dates date[] not null default '{}';
alter table events drop constraint if exists events_repeat_check;
alter table events add constraint events_repeat_check check (repeat in ('none','weekly','biweekly','monthly','monthly_nth','monthly_last'));
-- v27: any one-time event can get promotion reminders ("Promote it"). Entertainment events made before this had them, so they keep them.
do $$
begin
  if not exists (select 1 from information_schema.columns where table_schema = 'public' and table_name = 'events' and column_name = 'promote') then
    alter table events add column promote boolean not null default false;
    update events set promote = true where kind = 'entertainment' and repeat = 'none';
  end if;
end $$;
do $$
begin
  alter table events enable row level security;
  revoke all on table events from public;
  if exists (select 1 from pg_roles where rolname='anon') then revoke all on table events from anon; end if;
  if exists (select 1 from pg_roles where rolname='authenticated') then revoke all on table events from authenticated; end if;
end $$;

-- Keep an event's promotion tasks in line with the event. Returns how many new tasks it added.
--   Promoted (one-time) events: one starred task for managers 14, 7 and 1 days before. Ones already in the past aren't added.
--   Moving the event moves the tasks (and un-checks any whose date changed); one that would now be in the past goes away.
--   Not promoted: the promotion tasks that aren't done yet go away.
create or replace function _sync_event_tasks(p_ev events, p_me staff) returns int language plpgsql
set search_path = public, extensions as $$
declare lead int; due date; tk tasks; n int := 0; mrole text; label text; today date := _shift_day();
begin
  if not p_ev.promote or p_ev.repeat <> 'none' then
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
drop function if exists api_save_event(uuid, text, text, text, date, text, text, text);
drop function if exists api_save_event(uuid, text, text, text, date, text, text, text, text, date);
-- p_repeat null keeps what's there when changing an event (older app versions don't send it). Only Standard events repeat.
-- p_promote: add the promotion tasks. Null (older app versions) means: new Entertainment events yes, others no;
-- a changed event keeps its setting unless its type changed.
create or replace function api_save_event(p_token uuid, p_id text, p_title text, p_kind text, p_day date,
                                          p_start text default null, p_end text default null, p_notes text default '',
                                          p_repeat text default null, p_until date default null,
                                          p_promote boolean default null) returns text language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); ev events; old events; k text := lower(coalesce(nullif(trim(p_kind),''), 'standard')); n int;
        rp text := lower(nullif(trim(p_repeat),'')); un date := p_until; pr boolean := p_promote;
begin
  if coalesce(trim(p_title),'') = '' then raise exception 'empty'; end if;
  if p_day is null then raise exception 'bad_time'; end if;
  if k not in ('party','entertainment','standard','other') then k := 'other'; end if;
  if nullif(p_id,'') is not null then
    select * into old from events where id = p_id;
    if not found then raise exception 'not_found'; end if;
    if exists (select 1 from parties where event_id = p_id) then raise exception 'use_party'; end if;   -- change it from the party booking
    if rp is null then rp := old.repeat; un := old.repeat_until; end if;
    if pr is null and old.kind = k then pr := old.promote; end if;
  end if;
  rp := coalesce(rp, 'none');
  if rp not in ('none','weekly','biweekly','monthly','monthly_nth','monthly_last') or k <> 'standard' then rp := 'none'; end if;
  if rp = 'none' then un := null; end if;
  pr := coalesce(pr, k = 'entertainment') and rp = 'none';   -- repeating events don't get promotion tasks
  if un is not null and un < p_day then raise exception 'bad_time'; end if;
  if nullif(p_id,'') is null then
    insert into events (title, kind, day, start_time, end_time, notes, repeat, repeat_until, promote, added_by, added_by_name)
    values (left(trim(p_title), 120), k, p_day, _clean_time(p_start), _clean_time(p_end), left(coalesce(trim(p_notes),''), 1000), rp, un, pr, me.id, me.name)
    returning * into ev;
    perform _log(me, 'added', ev.title, 'Events');
  else
    update events set title = left(trim(p_title), 120), kind = k, day = p_day, start_time = _clean_time(p_start), end_time = _clean_time(p_end),
                      notes = left(coalesce(trim(p_notes),''), 1000), repeat = rp, repeat_until = un, promote = pr,
                      skip_dates = case when rp = 'none' then '{}' else array(select x from unnest(skip_dates) x where x >= p_day) end,
                      updated_at = now()
     where id = p_id returning * into ev;
    perform _log(me, 'edited', ev.title, 'Events');
  end if;
  n := _sync_event_tasks(ev, me);
  if n > 0 then perform _push_kick(); end if;   -- the other managers hear about the new promotion tasks
  return ev.id;
end $$;

-- Call off (or bring back) one date of a repeating event (managers).
create or replace function api_skip_event(p_token uuid, p_id text, p_day date, p_skip boolean default true) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); ev events;
begin
  select * into ev from events where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if p_day is null then raise exception 'bad_time'; end if;
  if (p_day = any(ev.skip_dates)) = coalesce(p_skip, true) then return; end if;   -- already that way
  update events set skip_dates = case when coalesce(p_skip, true)
                                      then array(select distinct x from unnest(skip_dates || p_day) x order by x)
                                      else array_remove(skip_dates, p_day) end,
                    updated_at = now()
   where id = p_id;
  perform _log(me, case when coalesce(p_skip, true) then 'skipped' else 'unskipped' end,
               ev.title || ' on ' || to_char(p_day, 'Dy Mon FMDD'), 'Events');
end $$;

-- Remove an event (managers). Its promotion tasks go with it. Removing a party's event cancels the booking.
create or replace function api_remove_event(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); ev events; pid text;
begin
  update parties set status = 'cancelled', decided_by_name = me.name, decided_at = now(), updated_at = now()
   where event_id = p_id and status in ('hold','booked') returning id into pid;
  delete from events where id = p_id returning * into ev;
  if found then perform _log(me, case when pid is null then 'removed' else 'cancelled' end, ev.title, case when pid is null then 'Events' else 'Parties' end); end if;
  if pid is not null then perform _sync_party(pid, me.id, me.name); end if;
end $$;

-- ---------- party bookings (added Oct 2026) ----------
-- Parties come in from the pub's Google Form (a small script on the form calls api_party_form), or a manager adds one.
--   status: inquiry (waiting for a reply) | hold (date held, waiting on the deposit) | booked (deposit paid) | declined | cancelled
-- Held and booked parties get a Party event on the calendar. A new inquiry gets a starred "reply to it" task for managers
-- (v39: holds and bookings no longer add deposit, headcount, party-day or thank-you tasks).
-- Staff see held and booked parties without the host's phone, email, deposit or manager notes.
create table if not exists parties (
  id text primary key default gen_random_uuid()::text,
  status text not null default 'inquiry' check (status in ('inquiry','hold','booked','declined','cancelled')),
  host_name text not null default '',
  phone text not null default '',
  email text not null default '',
  occasion text not null default '',
  day date,
  backup_day date,
  start_time time,
  end_time time,
  guests int,
  guests_text text not null default '',       -- what they typed on the form, e.g. "30-40"
  package text not null default '' check (package in ('','open_bar_food','open_bar','cash_bar','space')),
  notes text not null default '',             -- what they asked for; staff see this
  private_notes text not null default '',     -- managers only
  deposit numeric,
  deposit_paid_on date,
  deposit_how text not null default '',
  event_id text references events(id) on delete set null,
  source text not null default 'manual' check (source in ('form','manual')),
  form_id text unique,                        -- the Google Form response, so one is never added twice
  submitted_at timestamptz not null default now(),
  added_by text, added_by_name text,
  decided_by_name text, decided_at timestamptz,
  updated_at timestamptz not null default now()
);
create index if not exists parties_day_idx on parties (day);
alter table tasks add column if not exists party_id text references parties(id) on delete cascade;
alter table tasks add column if not exists party_step text;
-- Settings managers change in the app (party_deposit: the usual deposit, in dollars).
create table if not exists app_settings (name text primary key, value jsonb not null);
do $$
declare t text;
begin
  foreach t in array array['parties','app_settings'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on table %I from public', t);
    if exists (select 1 from pg_roles where rolname='anon') then execute format('revoke all on table %I from anon', t); end if;
    if exists (select 1 from pg_roles where rolname='authenticated') then execute format('revoke all on table %I from authenticated', t); end if;
  end loop;
end $$;
-- The password the Google Form script sends. Made once, here; it never leaves the database except to set up the script.
insert into app_secrets (name, value) values ('party_form_key', encode(extensions.gen_random_bytes(18), 'hex')) on conflict (name) do nothing;

-- v39: only inquiries get a task now; clear the open deposit, headcount, party-day and thank-you tasks.
delete from tasks where party_id is not null and party_step in ('deposit','confirm','setup','thanks') and not done;

-- The role tasks for managers go to.
create or replace function _mgr_role() returns text language sql stable
set search_path = public, extensions as $$
  select coalesce((select id from roles where id = 'manager'), (select id from roles where section = 'mgmt' order by sort, name limit 1))
$$;

-- "Sarah Miller" -> "Sarah M."
create or replace function _short_name(p text) returns text language sql immutable as $$
  select case when cardinality(w) = 0 then 'Guest'
              when cardinality(w) = 1 then upper(left(w[1],1)) || substr(w[1],2)
              else upper(left(w[1],1)) || substr(w[1],2) || ' ' || upper(left(w[cardinality(w)],1)) || '.' end
    from (select coalesce(array_remove(regexp_split_to_array(trim(coalesce(p,'')), '\s+'), ''), '{}') w) x
$$;

-- What shows on the calendar: "Sarah M. · Birthday"
create or replace function _party_title(p parties) returns text language sql immutable as $$
  select _short_name(p.host_name) || case when coalesce(trim(p.occasion),'') = '' then '''s party' else ' · ' || trim(p.occasion) end
$$;

create or replace function _pkg_label(p text) returns text language sql immutable as $$
  select case p when 'open_bar_food' then 'Open bar + food' when 'open_bar' then 'Open bar only'
                when 'cash_bar' then 'Cash bar' when 'space' then 'Just the space' else '' end
$$;

-- Dates from the form: 2026-11-22 or 11/22/2026. Anything else is null.
create or replace function _loose_date(p text) returns date language plpgsql immutable as $$
declare s text := trim(coalesce(p,''));
begin
  if s ~ '^\d{4}-\d{1,2}-\d{1,2}' then return substring(s from '^\d{4}-\d{1,2}-\d{1,2}')::date; end if;
  if s ~ '^\d{1,2}/\d{1,2}/\d{4}$' then return to_date(s, 'MM/DD/YYYY'); end if;
  return null;
exception when others then return null;
end $$;

-- Keep a party's calendar event and tasks in line with it. Returns how many new tasks it added.
create or replace function _sync_party(p_id text, p_who_id text, p_who_name text) returns int language plpgsql
set search_path = public, extensions as $$
declare p parties; ev_id text; today date := _shift_day(); mrole text := _mgr_role(); n int := 0; i int; tk tasks;
        who text; dstr text; dep numeric; steps text[] := '{}'; dues date[] := '{}'; labels text[] := '{}';
begin
  select * into p from parties where id = p_id;
  if not found then return 0; end if;
  who := _short_name(p.host_name);
  dstr := coalesce(to_char(p.day, 'Dy Mon FMDD'), 'no date yet');

  -- the calendar: held and booked parties are on it
  if p.status in ('hold','booked') and p.day is not null then
    if p.event_id is not null and exists (select 1 from events where id = p.event_id) then
      update events set title = _party_title(p), kind = 'party', day = p.day, start_time = p.start_time, end_time = p.end_time,
                        repeat = 'none', repeat_until = null, skip_dates = '{}', updated_at = now()
       where id = p.event_id;
    else
      insert into events (title, kind, day, start_time, end_time, notes, added_by, added_by_name)
      values (_party_title(p), 'party', p.day, p.start_time, p.end_time, '', p_who_id, coalesce(p_who_name, 'Party booking'))
      returning id into ev_id;
      update parties set event_id = ev_id where id = p.id;
    end if;
  elsif p.event_id is not null then
    update parties set event_id = null where id = p.id;
    delete from events where id = p.event_id;
  end if;

  -- the tasks this party needs right now
  if p.status = 'inquiry' then
    steps := array['reply'];
    dues := array[coalesce(_shift_day_at(p.decided_at), _shift_day_at(p.submitted_at))];
    labels := array['Reply to party inquiry: ' || who || coalesce(' · ' || nullif(trim(p.occasion),''), '') || ' · ' || dstr ||
                    coalesce(' · ~' || p.guests || ' guests', '')];
  end if;

  delete from tasks where party_id = p.id and not done and not (party_step = any(steps));
  for i in 1 .. coalesce(array_length(steps, 1), 0) loop
    select * into tk from tasks where party_id = p.id and party_step = steps[i] limit 1;
    if found then
      if tk.due_date is distinct from dues[i] and dues[i] < today and steps[i] in ('confirm','setup','thanks') and not tk.done then
        delete from tasks where id = tk.id;
      elsif tk.due_date is distinct from dues[i] then
        update tasks set text = labels[i], due_date = dues[i], done = false, done_day = null, done_due = null, done_until = null,
                         done_by = null, done_by_name = null, done_at = null where id = tk.id;
      else
        update tasks set text = labels[i] where id = tk.id;
      end if;
    elsif dues[i] >= today or steps[i] in ('reply','deposit') then
      insert into tasks (role_id, text, repeat, due_date, important, added_by, added_by_name, party_id, party_step, added_at)
      values (mrole, labels[i], 'once', dues[i], true, p_who_id, coalesce(p_who_name, 'Party form'), p.id, steps[i], clock_timestamp());
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- An inquiry from the Google Form. The script sends the form's password (p_key) and the answers.
-- Sending the same response twice does nothing. Inquiries for dates that have passed are skipped (returns null).
create or replace function api_party_form(p_key text, p_data jsonb) returns text language plpgsql
set search_path = public, extensions as $$
declare k text; p parties; d date; b date; g int; raw text; pk text; pkraw text; fid text := left(nullif(trim(p_data->>'response_id'),''), 200);
        sent timestamptz; notes text; n int;
begin
  select value into k from app_secrets where name = 'party_form_key';
  if k is null or p_key is distinct from k then raise exception 'bad_key'; end if;
  if fid is not null then
    select * into p from parties where form_id = fid;
    if found then return p.id; end if;
  end if;
  d := _loose_date(p_data->>'date'); b := _loose_date(p_data->>'backup');
  if d is null then d := b; b := null; end if;
  if d is null then raise exception 'bad_time'; end if;
  if greatest(d, coalesce(b, d)) < _shift_day() then return null; end if;
  if d < _shift_day() then d := b; b := null; end if;          -- first choice passed, back-up date hasn't
  raw := left(trim(coalesce(p_data->>'guests','')), 60);
  select max(left(m[1], 5)::int) into g from regexp_matches(raw, '(\d+)', 'g') m;   -- "30-40" -> 40
  if g < 1 or g > 5000 then g := null; end if;
  pkraw := trim(coalesce(p_data->>'package',''));
  pk := case when pkraw ~* 'food' then 'open_bar_food' when pkraw ~* 'open bar' then 'open_bar'
             when pkraw ~* 'cash' then 'cash_bar' when pkraw ~* 'space|reserv' then 'space' else '' end;
  notes := left(trim(coalesce(p_data->>'notes','')), 2000);
  if pk = '' and pkraw <> '' then notes := trim('Package: ' || left(pkraw, 100) || E'\n' || notes); end if;
  begin sent := (p_data->>'submitted_at')::timestamptz; exception when others then sent := null; end;
  if sent is null or sent > now() then sent := now(); end if;
  insert into parties (status, host_name, phone, email, occasion, day, backup_day, start_time, guests, guests_text, package, notes,
                       source, form_id, submitted_at)
  values ('inquiry', left(trim(coalesce(p_data->>'name','')), 80), left(trim(coalesce(p_data->>'phone','')), 40),
          left(trim(coalesce(p_data->>'email','')), 120), left(trim(coalesce(p_data->>'kind','')), 60), d, b,
          _clean_time(p_data->>'start'), g, raw, pk, notes, 'form', fid, sent)
  returning * into p;
  insert into log (day, who, who_name, kind, text, place)
  values (_shift_day(), null, coalesce(nullif(p.host_name,''), 'Someone'), 'inquiry',
          coalesce(nullif(p.occasion,''), 'Party') || ' on ' || to_char(p.day, 'Dy Mon FMDD') || coalesce(', ~' || p.guests || ' guests', ''), 'Parties');
  n := _sync_party(p.id, null, 'Party form');
  if n > 0 then perform _push_kick(); end if;
  return p.id;
end $$;

-- Add (p_id null) or change a party (managers). p_data holds the fields; a new one starts on hold, or booked if p_data.status = 'booked'.
create or replace function api_save_party(p_token uuid, p_id text, p_data jsonb) returns text language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); p parties; old parties; n int; d date := _loose_date(p_data->>'day'); b date := _loose_date(p_data->>'backup_day');
        pk text := coalesce(p_data->>'package',''); g int; dep numeric; st text := coalesce(p_data->>'status','hold');
begin
  if coalesce(trim(p_data->>'host_name'),'') = '' then raise exception 'empty'; end if;
  if d is null then raise exception 'bad_time'; end if;
  if pk not in ('open_bar_food','open_bar','cash_bar','space') then pk := ''; end if;
  begin g := nullif(p_data->>'guests','')::int; exception when others then g := null; end;
  if g is not null and (g < 1 or g > 5000) then g := null; end if;
  begin dep := nullif(p_data->>'deposit','')::numeric; exception when others then dep := null; end;
  if dep is not null and (dep < 0 or dep > 100000) then raise exception 'bad_amount'; end if;
  if nullif(p_id,'') is null then
    if st not in ('inquiry','hold','booked') then st := 'hold'; end if;
    insert into parties (status, host_name, phone, email, occasion, day, backup_day, start_time, end_time, guests, package, notes, private_notes,
                         deposit, deposit_paid_on, source, added_by, added_by_name, decided_by_name, decided_at)
    values (st, left(trim(p_data->>'host_name'), 80), left(trim(coalesce(p_data->>'phone','')), 40), left(trim(coalesce(p_data->>'email','')), 120),
            left(trim(coalesce(p_data->>'occasion','')), 60), d, b, _clean_time(p_data->>'start_time'), _clean_time(p_data->>'end_time'), g, pk,
            left(trim(coalesce(p_data->>'notes','')), 2000), left(trim(coalesce(p_data->>'private_notes','')), 2000),
            dep, case when st = 'booked' then _shift_day() end, 'manual', me.id, me.name, me.name, now())
    returning * into p;
    perform _log(me, 'added', _party_title(p) || ' on ' || to_char(p.day, 'Dy Mon FMDD'), 'Parties');
  else
    select * into old from parties where id = p_id for update;
    if not found then raise exception 'not_found'; end if;
    update parties set host_name = left(trim(p_data->>'host_name'), 80), phone = left(trim(coalesce(p_data->>'phone','')), 40),
                       email = left(trim(coalesce(p_data->>'email','')), 120), occasion = left(trim(coalesce(p_data->>'occasion','')), 60),
                       day = d, backup_day = b, start_time = _clean_time(p_data->>'start_time'), end_time = _clean_time(p_data->>'end_time'),
                       guests = g, guests_text = case when g is distinct from old.guests then '' else guests_text end, package = pk,
                       notes = left(trim(coalesce(p_data->>'notes','')), 2000), private_notes = left(trim(coalesce(p_data->>'private_notes','')), 2000),
                       deposit = dep, updated_at = now()
     where id = p_id returning * into p;
    perform _log(me, 'edited', _party_title(p), 'Parties');
  end if;
  n := _sync_party(p.id, me.id, me.name);
  if n > 0 then perform _push_kick(); end if;
  return p.id;
end $$;

-- Move a party along (managers): hold a date (p_day picks the date, e.g. their back-up), book, decline, cancel, or reopen as an inquiry.
create or replace function api_party_status(p_token uuid, p_id text, p_status text, p_day date default null) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); p parties; st text := lower(trim(coalesce(p_status,''))); n int;
begin
  if st not in ('inquiry','hold','booked','declined','cancelled') then raise exception 'bad_status'; end if;
  select * into p from parties where id = p_id for update;
  if not found then raise exception 'not_found'; end if;
  if p.status = st and (p_day is null or p_day = p.day) then return; end if;   -- already that way
  update parties set status = st,
                     day = coalesce(p_day, day),
                     backup_day = case when p_day is not null and p_day = backup_day then day else backup_day end,   -- picked their back-up: swap
                     deposit_paid_on = case when st = 'booked' then coalesce(deposit_paid_on, _shift_day()) else deposit_paid_on end,
                     decided_by_name = me.name, decided_at = now(), updated_at = now()
   where id = p_id returning * into p;
  perform _log(me, case st when 'hold' then 'held' when 'booked' then 'booked' when 'declined' then 'declined'
                           when 'cancelled' then 'cancelled' else 'reopened' end,
               _party_title(p) || ' on ' || to_char(p.day, 'Dy Mon FMDD'), 'Parties');
  n := _sync_party(p.id, me.id, me.name);
  if n > 0 then perform _push_kick(); end if;
end $$;

-- The deposit came in (managers): records it and books the party.
create or replace function api_party_deposit(p_token uuid, p_id text, p_amount numeric, p_paid_on date default null, p_how text default '') returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); p parties; n int;
begin
  if p_amount is null or p_amount < 0 or p_amount > 100000 then raise exception 'bad_amount'; end if;
  select * into p from parties where id = p_id for update;
  if not found or p.status not in ('inquiry','hold','booked') then raise exception 'not_found'; end if;
  update parties set deposit = p_amount, deposit_paid_on = coalesce(p_paid_on, _shift_day()), deposit_how = left(trim(coalesce(p_how,'')), 30),
                     status = 'booked', decided_by_name = me.name, decided_at = now(), updated_at = now()
   where id = p_id returning * into p;
  perform _log(me, 'deposit', _party_title(p) || ' on ' || to_char(p.day, 'Dy Mon FMDD') ||
               ' ($' || trim(to_char(p_amount, 'FM999999990.99'), '.') || ')', 'Parties');
  n := _sync_party(p.id, me.id, me.name);
  if n > 0 then perform _push_kick(); end if;
end $$;

-- Change a setting (managers), as a dollar amount, or null to clear it.
--   party_deposit: the usual party deposit
create or replace function api_set_setting(p_token uuid, p_name text, p_value jsonb) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); v numeric;
begin
  if p_name is distinct from 'party_deposit' then raise exception 'not_found'; end if;
  if p_value is null or p_value = 'null'::jsonb then delete from app_settings where name = p_name; return; end if;
  begin v := (p_value #>> '{}')::numeric; exception when others then raise exception 'bad_amount'; end;
  if v is null or v < 0 or v > 100000 then raise exception 'bad_amount'; end if;
  insert into app_settings (name, value) values (p_name, to_jsonb(v)) on conflict (name) do update set value = excluded.value;
  perform _log(me, 'edited', 'the party deposit ($' || trim(to_char(v, 'FM999999990.99'), '.') || ')', 'Parties');
end $$;

-- ---------- cash-out at close (added Nov 2026) ----------
-- Toast counts each drawer and prints a Closed Drawer Report. If its Expected deposit is negative, the drawer is short by
-- that much and a manager puts it back. At close the bartender records, per drawer, whether it's short and by how much
-- (short_amt); managers get an alert and mark it replenished. One cash-out per drawer per shift day; entering it again
-- replaces it. Managers see every night's; staff only see tonight's.
create table if not exists drawers (
  id text primary key default gen_random_uuid()::text,
  name text not null,
  bank numeric not null default 0,
  sort int not null default 0,
  active boolean not null default true,       -- a removed drawer stays so old cash-outs keep their name
  created_at timestamptz not null default now()
);
create table if not exists cashouts (
  id text primary key default gen_random_uuid()::text,
  day date not null,                          -- the shift day
  drawer_id text references drawers(id) on delete set null,
  drawer_name text not null,
  note text not null default '',
  by_id text, by_name text,
  at timestamptz not null default now(),
  first_at timestamptz not null default now(),
  edits int not null default 0,
  unique (day, drawer_id)
);
create index if not exists cashouts_day_idx on cashouts (day desc);
alter table cashouts add column if not exists short_amt numeric not null default 0;   -- 0 = not short
alter table cashouts add column if not exists replenished_at timestamptz;
alter table cashouts add column if not exists replenished_by_name text;
-- v48: the first version's bill-by-bill count is gone; so are its columns and settings.
alter table cashouts drop column if exists bank, drop column if exists cash_sales, drop column if exists card_tips,
  drop column if exists paid_outs, drop column if exists paid_out_note, drop column if exists bills, drop column if exists counted,
  drop column if exists expected, drop column if exists diff, drop column if exists drop_amt;
delete from app_settings where name in ('cash_tolerance','cash_math_v37');
drop function if exists _cash_tolerance();
drop function if exists _cash_result(numeric);
do $$
declare t text;
begin
  foreach t in array array['drawers','cashouts'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on table %I from public', t);
    if exists (select 1 from pg_roles where rolname='anon') then execute format('revoke all on table %I from anon', t); end if;
    if exists (select 1 from pg_roles where rolname='authenticated') then execute format('revoke all on table %I from authenticated', t); end if;
  end loop;
end $$;

-- "$12.50", "$200"
create or replace function _money(p numeric) returns text language sql immutable as $$
  select '$' || case when p = trunc(p) then to_char(abs(p), 'FM999,999,990') else to_char(abs(p), 'FM999,999,990.00') end
$$;

-- Add (p_id null) or change a drawer (managers).
create or replace function api_save_drawer(p_token uuid, p_id text, p_name text, p_bank numeric) returns text language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); n text := left(trim(coalesce(p_name,'')), 40); id_ text;
begin
  if n = '' then raise exception 'empty'; end if;
  if p_bank is null or p_bank < 0 or p_bank > 100000 then raise exception 'bad_amount'; end if;
  if exists (select 1 from drawers where active and lower(name) = lower(n) and id is distinct from p_id) then raise exception 'name_taken'; end if;
  if nullif(p_id,'') is null then
    insert into drawers (name, bank, sort) values (n, round(p_bank, 2), coalesce((select max(sort) + 1 from drawers), 0)) returning id into id_;
    perform _log(me, 'added', 'the ' || n || ' drawer', 'Cash');
  else
    update drawers set name = n, bank = round(p_bank, 2) where id = p_id and active returning id into id_;
    if id_ is null then raise exception 'not_found'; end if;
    perform _log(me, 'edited', 'the ' || n || ' drawer', 'Cash');
  end if;
  return id_;
end $$;

create or replace function api_remove_drawer(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); d drawers;
begin
  update drawers set active = false where id = p_id and active returning * into d;
  if found then perform _log(me, 'removed', 'the ' || d.name || ' drawer', 'Cash'); end if;
end $$;

-- Save a drawer's cash-out for tonight (front of house and managers): p_data = {"short": true|false, "amount": 6.22, "note": ""}.
-- Entering the same drawer again the same shift day replaces it. Managers can pass p_day to fix an earlier night.
create or replace function api_cash_out(p_token uuid, p_drawer_id text, p_data jsonb, p_day date default null) returns json language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); mgr boolean := _is_manager(me.roles); dr drawers; d date := _shift_day(); c cashouts; old cashouts;
        is_short boolean; amt numeric := 0;
begin
  if not mgr and not exists (select 1 from roles r where r.id = any(me.roles) and r.section = 'foh') then raise exception 'foh_only'; end if;
  if p_day is not null and p_day <> d then
    if not mgr then raise exception 'managers_only'; end if;
    if p_day > d or p_day < d - 400 then raise exception 'bad_time'; end if;
    d := p_day;
  end if;
  select * into dr from drawers where id = p_drawer_id;
  if not found or (not dr.active and not exists (select 1 from cashouts where drawer_id = dr.id and day = d)) then raise exception 'not_found'; end if;
  if jsonb_typeof(p_data->'short') is distinct from 'boolean' then raise exception 'bad_amount'; end if;
  is_short := (p_data->>'short')::boolean;
  if is_short then
    begin amt := round(nullif(trim(coalesce(p_data->>'amount','')), '')::numeric, 2); exception when others then raise exception 'bad_amount'; end;
    if amt is null or amt <= 0 then raise exception 'need_amount'; end if;
    if amt > 100000 then raise exception 'bad_amount'; end if;
  end if;
  select * into old from cashouts where day = d and drawer_id = dr.id for update;
  insert into cashouts (day, drawer_id, drawer_name, short_amt, note, by_id, by_name)
  values (d, dr.id, dr.name, amt, left(trim(coalesce(p_data->>'note','')), 1000), me.id, me.name)
  on conflict (day, drawer_id) do update set drawer_name = excluded.drawer_name, short_amt = excluded.short_amt,
     note = excluded.note, by_id = excluded.by_id, by_name = excluded.by_name, at = now(), edits = cashouts.edits + 1,
     replenished_at = case when excluded.short_amt = cashouts.short_amt then cashouts.replenished_at end,
     replenished_by_name = case when excluded.short_amt = cashouts.short_amt then cashouts.replenished_by_name end
  returning * into c;
  insert into log (day, who, who_name, kind, text, place)
  values (_shift_day(), me.id, me.name, case when old.id is null then 'cashout' else 'recount' end,
          'the ' || c.drawer_name || ' drawer' || case when d <> _shift_day() then ' for ' || to_char(d, 'Dy Mon FMDD') else '' end || ': ' ||
          case when amt > 0 then 'short ' || _money(amt) else 'not short' end, 'Cash');
  if amt > 0 then perform _push_kick(); end if;
  return row_to_json(c);
end $$;

-- A manager put the missing cash back (p_done false undoes it).
create or replace function api_replenish(p_token uuid, p_id text, p_done boolean default true) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); c cashouts;
begin
  update cashouts set replenished_at = case when p_done then now() end, replenished_by_name = case when p_done then me.name end
   where id = p_id and short_amt > 0 and (replenished_at is null) = coalesce(p_done, true) returning * into c;
  if found then
    perform _log(me, case when p_done then 'replenished' else 'unreplenished' end,
                 'the ' || c.drawer_name || ' drawer for ' || to_char(c.day, 'Dy Mon FMDD') || ' (' || _money(c.short_amt) || ')', 'Cash');
  end if;
end $$;

-- A cash-out entered by mistake (managers).
create or replace function api_remove_cashout(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); c cashouts;
begin
  delete from cashouts where id = p_id returning * into c;
  if found then perform _log(me, 'removed', 'the ' || c.drawer_name || ' cash-out for ' || to_char(c.day, 'Dy Mon FMDD'), 'Cash'); end if;
end $$;

-- ---------- notify a manager (added Nov 2026) ----------
-- Anyone can send the managers a quick heads-up about something: front or back of house, optionally to one manager.
-- Managers get a notification (one sent to them by name comes through even during their quiet hours) and mark it handled.
-- The sender sees whether it's been handled. Other staff don't see it.
create table if not exists manager_alerts (
  id text primary key default gen_random_uuid()::text,
  area text not null check (area in ('foh','boh')),
  to_staff text references staff(id) on delete set null,   -- null = any manager
  to_name text,
  text text not null,
  from_id text references staff(id) on delete set null,
  from_name text not null,
  at timestamptz not null default now(),
  handled_at timestamptz,
  handled_by_name text
);
create index if not exists manager_alerts_at_idx on manager_alerts (at desc);
do $$
begin
  alter table manager_alerts enable row level security;
  revoke all on table manager_alerts from public;
  if exists (select 1 from pg_roles where rolname='anon') then revoke all on table manager_alerts from anon; end if;
  if exists (select 1 from pg_roles where rolname='authenticated') then revoke all on table manager_alerts from authenticated; end if;
end $$;

-- Send the managers an alert (anyone logged in). p_area: foh | boh. p_to: one manager's id, or null for any manager.
create or replace function api_notify_manager(p_token uuid, p_area text, p_to text, p_text text) returns text language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); t text := left(trim(coalesce(p_text,'')), 600); m staff; id_ text;
begin
  if p_area is null or p_area not in ('foh','boh') then raise exception 'pick_area'; end if;
  if t = '' then raise exception 'empty'; end if;
  if (select count(*) from manager_alerts where from_id = me.id and at > now() - interval '10 minutes') >= 10 then raise exception 'too_many'; end if;
  if nullif(p_to,'') is not null then
    select * into m from staff where id = p_to;
    if not found or not _is_manager(m.roles) then raise exception 'not_found'; end if;
  end if;
  insert into manager_alerts (area, to_staff, to_name, text, from_id, from_name)
  values (p_area, m.id, m.name, t, me.id, me.name) returning id into id_;
  perform _log(me, 'alerted', case when m.id is null then 'the managers' else m.name end || ' (' ||
               case p_area when 'foh' then 'front of house' else 'back of house' end || '): ' || left(t, 120), 'Alerts');
  perform _push_kick();
  return id_;
end $$;

-- Managers: mark an alert handled (p_done false reopens it).
create or replace function api_handle_alert(p_token uuid, p_id text, p_done boolean default true) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); a manager_alerts;
begin
  update manager_alerts set handled_at = case when p_done then now() end, handled_by_name = case when p_done then me.name end
   where id = p_id and (handled_at is null) = coalesce(p_done, true) returning * into a;
  if found then perform _log(me, case when p_done then 'handled' else 'reopened' end, a.from_name || '’s alert: ' || left(a.text, 120), 'Alerts'); end if;
end $$;

-- ---------- daily cash (added Nov 2026) ----------
-- The day's cash sales, the cash paid out (to whom, how much) and the cash left over, counted by hand.
-- ONLY the people listed in cash_book_access can see or change it: Aidan, Tom and Mandy. Being a manager is not enough.
-- That list can only be changed here in the SQL editor; nothing in the app can add anyone to it.
-- Saving a day notifies the others on the list. Nothing about it goes in the activity log.
create table if not exists cash_book_access (staff_id text primary key references staff(id) on delete cascade);
create table if not exists daily_cash (
  day date primary key,
  cash_sales numeric not null,
  payouts jsonb not null default '[]',        -- [{"who":"Mark","amount":551}, ...]
  payouts_total numeric not null default 0,
  left_over numeric not null,
  note text not null default '',
  by_id text, by_name text,
  at timestamptz not null default now(),
  first_at timestamptz not null default now(),
  edits int not null default 0
);
do $$
declare t text;
begin
  foreach t in array array['cash_book_access','daily_cash'] loop
    execute format('alter table %I enable row level security', t);
    execute format('revoke all on table %I from public', t);
    if exists (select 1 from pg_roles where rolname='anon') then execute format('revoke all on table %I from anon', t); end if;
    if exists (select 1 from pg_roles where rolname='authenticated') then execute format('revoke all on table %I from authenticated', t); end if;
  end loop;
end $$;
insert into cash_book_access (staff_id) select id from staff where name in ('Aidan','Tom','Mandy') on conflict do nothing;

create or replace function _can_cash_book(p_id text) returns boolean language sql stable
set search_path = public, extensions as $$
  select exists (select 1 from cash_book_access where staff_id = p_id)
$$;
create or replace function _cash_booker(p_token uuid) returns staff language plpgsql stable
set search_path = public, extensions as $$
declare s staff := _me(p_token);
begin
  if not _can_cash_book(s.id) then raise exception 'not_allowed'; end if;
  return s;
end $$;

-- Save a day (p_data: cash_sales, payouts [{who, amount}], left_over, note). Saving the same day again replaces it.
create or replace function api_daily_cash_save(p_token uuid, p_day date, p_data jsonb) returns json language plpgsql
set search_path = public, extensions as $$
declare me staff := _cash_booker(p_token); d daily_cash; sales numeric; lo numeric; p jsonb; who text; amt numeric;
        pays jsonb := '[]'; total numeric := 0;
begin
  if p_day is null or p_day > _shift_day() or p_day < _shift_day() - 400 then raise exception 'bad_time'; end if;
  begin
    sales := round(nullif(trim(coalesce(p_data->>'cash_sales','')), '')::numeric, 2);
    lo := round(nullif(trim(coalesce(p_data->>'left_over','')), '')::numeric, 2);
  exception when others then raise exception 'bad_amount'; end;
  if sales is null or lo is null then raise exception 'need_numbers'; end if;
  if sales < 0 or sales > 1000000 or lo < -1000000 or lo > 1000000 then raise exception 'bad_amount'; end if;
  if jsonb_typeof(coalesce(p_data->'payouts','[]')) <> 'array' or jsonb_array_length(coalesce(p_data->'payouts','[]')) > 40 then raise exception 'bad_amount'; end if;
  for p in select * from jsonb_array_elements(coalesce(p_data->'payouts','[]')) loop
    who := left(trim(coalesce(p->>'who','')), 60);
    begin amt := round(nullif(trim(coalesce(p->>'amount','')), '')::numeric, 2); exception when others then raise exception 'bad_amount'; end;
    continue when who = '' and amt is null;
    if who = '' then raise exception 'need_payee'; end if;
    if amt is null or amt <= 0 or amt > 1000000 then raise exception 'bad_amount'; end if;
    pays := pays || jsonb_build_object('who', who, 'amount', amt);
    total := total + amt;
  end loop;
  insert into daily_cash (day, cash_sales, payouts, payouts_total, left_over, note, by_id, by_name)
  values (p_day, sales, pays, total, lo, left(trim(coalesce(p_data->>'note','')), 1000), me.id, me.name)
  on conflict (day) do update set cash_sales = excluded.cash_sales, payouts = excluded.payouts, payouts_total = excluded.payouts_total,
     left_over = excluded.left_over, note = excluded.note, by_id = excluded.by_id, by_name = excluded.by_name, at = now(), edits = daily_cash.edits + 1
  returning * into d;
  perform _push_kick();
  return row_to_json(d);
end $$;

create or replace function api_daily_cash_delete(p_token uuid, p_day date) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _cash_booker(p_token);
begin
  delete from daily_cash where day = p_day;
end $$;

-- ---------- live updates (v49) ----------
-- After any change people would see, tell every open copy of the app "something changed" over Supabase Realtime,
-- so it reloads within a second instead of waiting for the next 15-second check. The message carries no data:
-- each phone still reads what it's allowed to see through api_state. One message per database transaction.
create or replace function _live_ping() returns trigger language plpgsql
set search_path = public, extensions as $$
begin
  if tg_table_name = 'log' and tg_op = 'DELETE' then return null; end if;   -- trimming old activity isn't news
  if current_setting('brewskis.live_pinged', true) = 'y' then return null; end if;
  perform set_config('brewskis.live_pinged', 'y', true);
  begin
    perform realtime.send(jsonb_build_object('t', extract(epoch from clock_timestamp())), 'changed', 'brewskis-live', false);
  exception when others then null;   -- live updates are a nicety: never let them block a save
  end;
  return null;
end $$;

do $$
declare t text;
begin
  foreach t in array array['roles','staff','logins','tasks','invcats','suppliers','items','counts','log','shifts','shift_swaps',
                           'events','parties','app_settings','drawers','cashouts','manager_alerts','daily_cash'] loop
    if to_regclass('public.' || t) is not null then
      execute format('drop trigger if exists live_ping on %I', t);
      execute format('create trigger live_ping after insert or update or delete on %I for each row execute function _live_ping()', t);
    end if;
  end loop;
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
