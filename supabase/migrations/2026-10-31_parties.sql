-- Version 34: party bookings.
-- Run this once in Supabase > SQL Editor. It is safe to run again.
-- Adds the parties table, the Google Form intake (api_party_form), holds, deposits, the staff party sheet,
-- and party tasks and alerts for managers.


-- ---------- party bookings (added Oct 2026) ----------
-- Parties come in from the pub's Google Form (a small script on the form calls api_party_form), or a manager adds one.
--   status: inquiry (waiting for a reply) | hold (date held, waiting on the deposit) | booked (deposit paid) | declined | cancelled
-- Held and booked parties get a Party event on the calendar, and starred tasks for managers:
--   inquiry: reply to it · hold: get the deposit · booked: confirm headcount 3 days before, set up on the day, thank them and settle up the day after.
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
  elsif p.status = 'hold' then
    dep := coalesce(p.deposit, (select (value #>> '{}')::numeric from app_settings where name = 'party_deposit'));
    steps := array['deposit'];
    dues := array[coalesce(_shift_day_at(p.decided_at), today)];
    labels := array['Get the ' || coalesce('$' || trim(to_char(dep, 'FM999999990.99'), '.') || ' ', '') || 'deposit from ' || who ||
                    ' to lock in ' || dstr || coalesce(' (' || nullif(trim(p.occasion),'') || ')', '')];
  elsif p.status = 'booked' and p.day is not null then
    steps := array['confirm','setup','thanks'];
    dues := array[p.day - 3, p.day, p.day + 1];
    labels := array['Call ' || who || ' to confirm headcount and package for ' || dstr,
                    'Party today: ' || _party_title(p) || coalesce(', ~' || p.guests || ' guests', '') ||
                      coalesce(', ' || to_char(p.start_time, 'FMHH12:MI AM'), '') || coalesce(' · ' || nullif(_pkg_label(p.package),''), ''),
                    'Thank ' || who || ' and settle up for the party on ' || dstr];
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

-- Change a setting (managers). party_deposit: a dollar amount, or null to clear it.
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



-- api_state: parties and settings
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
    'log', coalesce((select json_agg(x order by x.at desc) from (
        select id, at, who, who_name, kind, text, place from log
         where mgr or kind <> 'ordered' order by at desc limit 1000) x), '[]')
  );
end $$;

-- api_save_event: a party's event is changed from the booking
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

-- api_remove_event: removing a party's event cancels the booking
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

-- notifications: new party inquiries get their own alert
create or replace function _push_collect(p_now timestamptz default now()) returns jsonb language plpgsql
set search_path = public, extensions as $$
declare tz text := 'America/New_York'; lnow timestamp := p_now at time zone tz; tnow time := lnow::time;
        today date := _shift_day_at(p_now); covered date;
        sub record; p jsonb; out jsonb := '[]'; tag text; k text; rc int;
        sup suppliers; nx timestamptz; n_low int;
        r record; ov_title text[]; ov_body text[]; os_title text[]; os_body text[];
        total int; done_n int; missed text[]; n_over int; n_out int; body text; st time; due_now boolean;
        endpoint_key text; quiet boolean; sw text[]; cv text[]; mgr boolean; nt text[]; nt_star boolean; nt_party int;
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
          total := done_n + n_over + n_out;
          if total > 0 then
            body := case done_n when 0 then 'No tasks checked off.' when 1 then '1 task checked off.' else done_n || ' tasks checked off.' end;
            if n_over > 0 then
              body := body || ' Overdue: ' || array_to_string(missed[1:3], ', ') ||
                      case when n_over > 3 then ' and ' || (n_over - 3) || ' more' else '' end || '.';
            end if;
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

