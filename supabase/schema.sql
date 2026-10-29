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
    'invcats', coalesce((select json_agg(c order by c.sort, c.name) from invcats c), '[]'),
    'items', coalesce((select json_agg(json_build_object('id', i.id, 'cat_id', i.cat_id, 'name', i.name, 'unit', i.unit, 'par', i.par,
        'supplier_id', case when mgr then i.supplier_id end, 'added_at', i.added_at) order by i.added_at, i.name) from items i), '[]'),
    'counts', coalesce((select json_agg(c) from counts c), '[]'),
    'suppliers', case when mgr then coalesce((select json_agg(s order by s.name) from suppliers s), '[]') else '[]' end,
    'log', coalesce((select json_agg(x order by x.at desc) from (
        select id, at, who, who_name, kind, text, place from log
         where mgr or kind <> 'ordered' order by at desc limit 1000) x), '[]')
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
  if not (_is_manager(me.roles) or t.added_by = me.id) then raise exception 'managers_only'; end if;
  delete from tasks where id = p_id;
  select name into rname from roles where id = t.role_id;
  perform _log(me, 'removed', t.text, rname);
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
declare d jsonb := '{"orders":true,"lead_hours":2,"overdue":true,"out":true,"summary":true,"summary_time":"09:00","quiet":true,"quiet_start":"00:00","quiet_end":"08:00"}';
        r jsonb := d; k text;
begin
  p := coalesce(p, '{}');
  foreach k in array array['orders','overdue','out','summary','quiet'] loop
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
        endpoint_key text; quiet boolean;
begin
  delete from push_sent where sent_at < p_now - interval '45 days';
  for sub in select ps.* from push_subs ps join staff stf on stf.id = ps.staff_id
              where _is_manager(stf.roles) and exists (select 1 from logins l where l.staff_id = stf.id) loop
    p := _push_prefs(sub.prefs);
    quiet := _push_quiet(p, tnow);   -- quiet hours hold back alerts, but not the recap (its time is picked on purpose)
    endpoint_key := md5(sub.endpoint);

    -- 1. order deadlines coming up that haven't been ordered
    if (p->>'orders')::boolean and not quiet then
      for sup in select * from suppliers order by name loop
        nx := _sup_next(sup, p_now);
        continue when nx is null or nx - make_interval(hours => (p->>'lead_hours')::int) > p_now or _sup_ordered(sup, p_now);
        k := 'order:' || endpoint_key || ':' || sup.id || ':' || extract(epoch from nx)::bigint;
        insert into push_sent(key) values (k) on conflict do nothing; get diagnostics rc = row_count;
        continue when rc = 0;
        select count(*) into n_low from items i join counts c on c.item_id = i.id
         where i.supplier_id = sup.id and i.par is not null and c.on_hand < i.par;
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', 'Order due: ' || sup.name,
          'body', 'Order by ' || _fmt_due(nx, p_now) || '. ' ||
                  case n_low when 0 then 'Nothing below par right now.' when 1 then '1 item below par.' else n_low || ' items below par.' end,
          'url', './#inventory', 'tag', 'order-' || sup.id);
      end loop;
    end if;

    -- 2. overdue tasks (daily tasks only count when they have a due time)
    if (p->>'overdue')::boolean and not quiet then
      ov_title := '{}'; ov_body := '{}';
      for r in
        select x.* from (
          select tk.id, tk.text, ro.name as rname,
                 case when tk.repeat = 'daily' then today else tk.due_date end as occ,
                 _deadline(case when tk.repeat = 'daily' then today else tk.due_date end, tk.due_time) as dl
            from tasks tk join roles ro on ro.id = tk.role_id
           where (tk.repeat = 'daily' and tk.due_time is not null and tk.done_day is distinct from today)
              or (tk.repeat in ('weekly','biweekly','monthly') and tk.due_date is not null and (tk.done_until is null or tk.done_until <= p_now))
              or (tk.repeat = 'once' and tk.due_date is not null and not tk.done)) x
         where x.dl < p_now order by x.dl
      loop
        k := 'overdue:' || endpoint_key || ':' || r.id || ':' || r.occ;
        insert into push_sent(key) values (k) on conflict do nothing; get diagnostics rc = row_count;
        continue when rc = 0;
        ov_title := ov_title || r.text;
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
    if (p->>'out')::boolean and not quiet then
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

    -- 4. nightly recap of a finished shift day
    if (p->>'summary')::boolean then
      st := (p->>'summary_time')::time;
      covered := (lnow - interval '5 hours')::date;
      if tnow >= time '05:00' then covered := covered - 1; end if;
      -- sent at the chosen time the morning after the shift day ends (or that night, for times before 5 AM); up to 3 hours late if a check is missed
      due_now := lnow >= (covered + 1) + st and lnow < (covered + 1) + st + interval '3 hours';
      if due_now then
        k := 'summary:' || endpoint_key || ':' || covered;
        insert into push_sent(key) values (k) on conflict do nothing; get diagnostics rc = row_count;
        if rc > 0 then
          with last_ev as (
            select distinct on (text, place) text, place, kind from log
             where day = covered and kind in ('done','undone') order by text, place, at desc),
          daily as (
            select tk.text, ro.name as place from tasks tk join roles ro on ro.id = tk.role_id
             where tk.repeat = 'daily' and tk.added_at < ((covered + 1) + time '05:00') at time zone tz)
          select count(*), count(*) filter (where le.kind = 'done'),
                 coalesce(array_agg(d.text order by d.place, d.text) filter (where le.kind is distinct from 'done'), '{}')
            into total, done_n, missed
            from daily d left join last_ev le on le.text = d.text and le.place = d.place;
          select count(*) into n_over from tasks tk
           where ((tk.repeat in ('weekly','biweekly','monthly') and (tk.done_until is null or tk.done_until <= p_now))
                  or (tk.repeat = 'once' and not tk.done))
             and tk.due_date is not null and _deadline(tk.due_date, tk.due_time) < p_now;
          select count(*) into n_out from counts c join items i on i.id = c.item_id where c.on_hand <= 0 and coalesce(i.par, 0) > 0;
          if total > 0 then
            body := done_n || ' of ' || total || ' checklist tasks done.';
            if coalesce(array_length(missed, 1), 0) > 0 then
              body := body || ' Not done: ' || array_to_string(missed[1:3], ', ') ||
                      case when array_length(missed, 1) > 3 then ' and ' || (array_length(missed, 1) - 3) || ' more' else '' end || '.';
            end if;
            if n_over > 0 then body := body || ' ' || n_over || case when n_over = 1 then ' task' else ' tasks' end || ' overdue.'; end if;
            if n_out > 0 then body := body || ' ' || n_out || case when n_out = 1 then ' item' else ' items' end || ' out.'; end if;
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
declare me staff := _mgr(p_token); pr jsonb := _push_prefs(p_prefs);
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
