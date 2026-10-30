-- Version 25: repeating Standard events.
-- Paste this whole file into the Supabase SQL Editor and click Run. Safe to run more than once.
-- Lets a Standard event repeat (weekly, every 2 weeks, monthly) and lets managers call off a single date.

-- v25: Standard events can repeat. day is the first date; the app works out the rest.
--   repeat: none | weekly | biweekly | monthly (same date) | monthly_nth (e.g. 2nd Tuesday) | monthly_last (e.g. last Friday)
--   repeat_until: last date it can happen (null = keeps going); skip_dates: single dates that are called off
alter table events add column if not exists repeat text not null default 'none';
alter table events add column if not exists repeat_until date;
alter table events add column if not exists skip_dates date[] not null default '{}';
alter table events drop constraint if exists events_repeat_check;
alter table events add constraint events_repeat_check check (repeat in ('none','weekly','biweekly','monthly','monthly_nth','monthly_last'));

-- everything the app shows now includes repeating events that are still going
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
                          'repeat', e.repeat, 'repeat_until', e.repeat_until, 'skip_dates', e.skip_dates)
                          order by e.day, e.start_time nulls first, e.title)
                        from events e where e.day >= _shift_day() - 70
                           or (e.repeat <> 'none' and (e.repeat_until is null or e.repeat_until >= _shift_day() - 70))), '[]'),
    'log', coalesce((select json_agg(x order by x.at desc) from (
        select id, at, who, who_name, kind, text, place from log
         where mgr or kind <> 'ordered' order by at desc limit 1000) x), '[]')
  );
end $$;

drop function if exists api_save_event(uuid, text, text, text, date, text, text, text);
-- p_repeat null keeps what's there when changing an event (older app versions don't send it). Only Standard events repeat.
create or replace function api_save_event(p_token uuid, p_id text, p_title text, p_kind text, p_day date,
                                          p_start text default null, p_end text default null, p_notes text default '',
                                          p_repeat text default null, p_until date default null) returns text language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); ev events; old events; k text := lower(coalesce(nullif(trim(p_kind),''), 'standard')); n int;
        rp text := lower(nullif(trim(p_repeat),'')); un date := p_until;
begin
  if coalesce(trim(p_title),'') = '' then raise exception 'empty'; end if;
  if p_day is null then raise exception 'bad_time'; end if;
  if k not in ('party','entertainment','standard','other') then k := 'other'; end if;
  if nullif(p_id,'') is not null then
    select * into old from events where id = p_id;
    if not found then raise exception 'not_found'; end if;
    if rp is null then rp := old.repeat; un := old.repeat_until; end if;
  end if;
  rp := coalesce(rp, 'none');
  if rp not in ('none','weekly','biweekly','monthly','monthly_nth','monthly_last') or k <> 'standard' then rp := 'none'; end if;
  if rp = 'none' then un := null; end if;
  if un is not null and un < p_day then raise exception 'bad_time'; end if;
  if nullif(p_id,'') is null then
    insert into events (title, kind, day, start_time, end_time, notes, repeat, repeat_until, added_by, added_by_name)
    values (left(trim(p_title), 120), k, p_day, _clean_time(p_start), _clean_time(p_end), left(coalesce(trim(p_notes),''), 1000), rp, un, me.id, me.name)
    returning * into ev;
    perform _log(me, 'added', ev.title, 'Events');
  else
    update events set title = left(trim(p_title), 120), kind = k, day = p_day, start_time = _clean_time(p_start), end_time = _clean_time(p_end),
                      notes = left(coalesce(trim(p_notes),''), 1000), repeat = rp, repeat_until = un,
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
