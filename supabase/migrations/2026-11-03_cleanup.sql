-- Version 48 cleanup: removes what the first version of the drawer cash-out left behind (its bill-by-bill columns,
-- the "flag a drawer" setting and two helper functions). Nothing in the app uses them; no cash-outs used them.
-- Safe to run more than once.

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

-- v48: the first version's bill-by-bill count is gone; so are its columns and settings.
alter table cashouts drop column if exists bank, drop column if exists cash_sales, drop column if exists card_tips,
  drop column if exists paid_outs, drop column if exists paid_out_note, drop column if exists bills, drop column if exists counted,
  drop column if exists expected, drop column if exists diff, drop column if exists drop_amt;
delete from app_settings where name in ('cash_tolerance','cash_math_v37');
drop function if exists _cash_tolerance();
drop function if exists _cash_result(numeric);

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
