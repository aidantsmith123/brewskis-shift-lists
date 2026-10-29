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

create or replace function api_save_supplier(p_token uuid, p_id text, p_name text, p_days int[], p_cutoff text, p_notes text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  if coalesce(trim(p_name),'') = '' then raise exception 'empty'; end if;
  if coalesce(p_cutoff,'') !~ '^\d{2}:\d{2}$' then p_cutoff := '14:00'; end if;
  if p_id is null or p_id = '' then
    insert into suppliers (name, days, cutoff, notes) values (trim(p_name), coalesce(p_days,'{}'), p_cutoff, coalesce(trim(p_notes),''));
  else
    update suppliers set name = trim(p_name), days = coalesce(p_days,'{}'), cutoff = p_cutoff, notes = coalesce(trim(p_notes),'') where id = p_id;
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
