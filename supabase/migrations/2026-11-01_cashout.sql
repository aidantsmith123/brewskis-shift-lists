-- Version 35: cash-out at close.
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run. Safe to run more than once.
-- Adds the drawers and cashouts tables and their functions, and updates api_state, api_set_setting and the alerts.

-- ---------- cash-out at close (added Nov 2026) ----------
-- Managers set up the cash drawers and each one's starting bank. At close, a bartender counts a drawer bill by bill
-- (before pulling tips) and types in the cash sales and card tips from Toast's report:
--   expected = bank + cash sales - paid outs      over/short = counted - expected
--   then: pay out the card tips, leave the bank, and drop the rest (counted - bank - card tips).
-- One cash-out per drawer per shift day; counting again replaces it. Managers get an alert when one is off by more
-- than the cash_tolerance setting (default $5), and see every night's cash-outs. Staff only see tonight's.
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
  bank numeric not null default 0,
  cash_sales numeric not null default 0,      -- from Toast
  card_tips numeric not null default 0,       -- from Toast; paid out of the drawer
  paid_outs numeric not null default 0,       -- cash taken out for something else (a delivery, the DJ…)
  paid_out_note text not null default '',
  bills jsonb not null default '{}',          -- {"100":2,"50":1,"20":31,...,"coins":4.35}
  counted numeric not null default 0,
  expected numeric not null default 0,
  diff numeric not null default 0,            -- counted - expected: + over, - short
  drop_amt numeric not null default 0,        -- counted - bank - card tips
  note text not null default '',
  by_id text, by_name text,
  at timestamptz not null default now(),
  first_at timestamptz not null default now(),
  edits int not null default 0,
  unique (day, drawer_id)
);
create index if not exists cashouts_day_idx on cashouts (day desc);
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
create or replace function _cash_tolerance() returns numeric language sql stable
set search_path = public, extensions as $$
  select coalesce((select (value #>> '{}')::numeric from app_settings where name = 'cash_tolerance'), 5)
$$;
-- "balanced", "$12.50 short", "$3 over"
create or replace function _cash_result(p_diff numeric) returns text language sql stable as $$
  select case when abs(p_diff) < 0.005 then 'balanced' when p_diff < 0 then _money(p_diff) || ' short' else _money(p_diff) || ' over' end
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
    perform _log(me, 'added', 'the ' || n || ' drawer (' || _money(p_bank) || ' bank)', 'Cash');
  else
    update drawers set name = n, bank = round(p_bank, 2) where id = p_id and active returning id into id_;
    if id_ is null then raise exception 'not_found'; end if;
    perform _log(me, 'edited', 'the ' || n || ' drawer (' || _money(p_bank) || ' bank)', 'Cash');
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

-- Save a drawer's cash-out for tonight (front of house and managers). Counting the same drawer again the same shift day
-- replaces it. Managers can pass p_day to fix an earlier night. Returns the saved cash-out.
-- p_data: bills {"100":n,"50":n,"20":n,"10":n,"5":n,"1":n,"coins":dollars}, cash_sales, card_tips, paid_outs, paid_out_note, bank, note
create or replace function api_cash_out(p_token uuid, p_drawer_id text, p_data jsonb, p_day date default null) returns json language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); mgr boolean := _is_manager(me.roles); dr drawers; d date := _shift_day(); c cashouts; old cashouts;
        b jsonb := coalesce(p_data->'bills', '{}'); den text; n numeric; bills jsonb := '{}'; counted numeric := 0;
        sales numeric; tips numeric; pouts numeric; bank numeric; expected numeric;
begin
  if not mgr and not exists (select 1 from roles r where r.id = any(me.roles) and r.section = 'foh') then raise exception 'foh_only'; end if;
  if p_day is not null and p_day <> d then
    if not mgr then raise exception 'managers_only'; end if;
    if p_day > d or p_day < d - 400 then raise exception 'bad_time'; end if;
    d := p_day;
  end if;
  select * into dr from drawers where id = p_drawer_id;
  if not found or (not dr.active and not exists (select 1 from cashouts where drawer_id = dr.id and day = d)) then raise exception 'not_found'; end if;
  if jsonb_typeof(b) <> 'object' then raise exception 'bad_amount'; end if;
  foreach den in array array['100','50','20','10','5','2','1'] loop
    begin n := nullif(b->>den, '')::numeric; exception when others then raise exception 'bad_amount'; end;
    continue when n is null or n = 0;
    if n < 0 or n > 5000 or n <> trunc(n) then raise exception 'bad_amount'; end if;
    bills := bills || jsonb_build_object(den, n::int);
    counted := counted + n * den::int;
  end loop;
  begin n := nullif(b->>'coins', '')::numeric; exception when others then raise exception 'bad_amount'; end;
  if n is not null and n <> 0 then
    if n < 0 or n > 10000 then raise exception 'bad_amount'; end if;
    bills := bills || jsonb_build_object('coins', round(n, 2));
    counted := counted + round(n, 2);
  end if;
  begin
    sales := round(nullif(p_data->>'cash_sales', '')::numeric, 2);
    tips  := round(coalesce(nullif(p_data->>'card_tips', '')::numeric, 0), 2);
    pouts := round(coalesce(nullif(p_data->>'paid_outs', '')::numeric, 0), 2);
    bank  := round(coalesce(nullif(p_data->>'bank', '')::numeric, dr.bank), 2);
  exception when others then raise exception 'bad_amount'; end;
  if sales is null then raise exception 'need_sales'; end if;
  if sales < 0 or sales > 1000000 or tips < 0 or tips > 1000000 or pouts < 0 or pouts > 1000000 or bank < 0 or bank > 100000 then raise exception 'bad_amount'; end if;
  expected := bank + sales - pouts;
  select * into old from cashouts where day = d and drawer_id = dr.id for update;
  insert into cashouts (day, drawer_id, drawer_name, bank, cash_sales, card_tips, paid_outs, paid_out_note, bills, counted, expected, diff, drop_amt, note, by_id, by_name)
  values (d, dr.id, dr.name, bank, sales, tips, pouts, left(trim(coalesce(p_data->>'paid_out_note','')), 200), bills, counted, expected,
          counted - expected, counted - bank - tips, left(trim(coalesce(p_data->>'note','')), 1000), me.id, me.name)
  on conflict (day, drawer_id) do update set drawer_name = excluded.drawer_name, bank = excluded.bank, cash_sales = excluded.cash_sales,
     card_tips = excluded.card_tips, paid_outs = excluded.paid_outs, paid_out_note = excluded.paid_out_note, bills = excluded.bills,
     counted = excluded.counted, expected = excluded.expected, diff = excluded.diff, drop_amt = excluded.drop_amt, note = excluded.note,
     by_id = excluded.by_id, by_name = excluded.by_name, at = now(), edits = cashouts.edits + 1
  returning * into c;
  insert into log (day, who, who_name, kind, text, place)
  values (_shift_day(), me.id, me.name, case when old.id is null then 'cashout' else 'recount' end,
          'the ' || c.drawer_name || ' drawer' || case when d <> _shift_day() then ' for ' || to_char(d, 'Dy Mon FMDD') else '' end || ': ' || _cash_result(c.diff), 'Cash');
  if abs(c.diff) > _cash_tolerance() then perform _push_kick(); end if;
  return row_to_json(c);
end $$;

-- A cash-out entered by mistake (managers).
create or replace function api_remove_cashout(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); c cashouts;
begin
  delete from cashouts where id = p_id returning * into c;
  if found then perform _log(me, 'removed', 'the ' || c.drawer_name || ' cash-out for ' || to_char(c.day, 'Dy Mon FMDD'), 'Cash'); end if;
end $$;


-- ---------- updated functions ----------
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
                  'party_form_last', (select max(submitted_at) from parties where source = 'form'),
                  'cash_tolerance', _cash_tolerance()) else '{}'::json end,
    'drawers', coalesce((select json_agg(json_build_object('id', d.id, 'name', d.name, 'bank', d.bank) order by d.sort, d.name)
                        from drawers d where d.active), '[]'),
    -- managers: the last 3 months of cash-outs; everyone else: tonight's
    'cashouts', coalesce((select json_agg(c order by c.day desc, c.drawer_name) from cashouts c
                          where c.day >= _shift_day() - case when mgr then 92 else 0 end), '[]'),
    'log', coalesce((select json_agg(x order by x.at desc) from (
        select id, at, who, who_name, kind, text, place from log
         where mgr or (kind <> 'ordered' and place <> 'Cash') order by at desc limit 1000) x), '[]')
  );
end $$;

create or replace function api_set_setting(p_token uuid, p_name text, p_value jsonb) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token); v numeric;
begin
  if p_name is null or p_name not in ('party_deposit','cash_tolerance') then raise exception 'not_found'; end if;
  if p_value is null or p_value = 'null'::jsonb then delete from app_settings where name = p_name; return; end if;
  begin v := (p_value #>> '{}')::numeric; exception when others then raise exception 'bad_amount'; end;
  if v is null or v < 0 or v > 100000 then raise exception 'bad_amount'; end if;
  insert into app_settings (name, value) values (p_name, to_jsonb(v)) on conflict (name) do update set value = excluded.value;
  if p_name = 'party_deposit' then
    perform _log(me, 'edited', 'the party deposit ($' || trim(to_char(v, 'FM999999990.99'), '.') || ')', 'Parties');
  else
    perform _log(me, 'edited', 'the cash-out alert (off by more than ' || _money(v) || ')', 'Cash');
  end if;
end $$;

create or replace function _push_prefs(p jsonb) returns jsonb language plpgsql immutable as $$
declare d jsonb := '{"orders":true,"lead_hours":2,"overdue":true,"out":true,"summary":true,"swaps":true,"coverage":true,"tasks":true,"cash":true,"summary_time":"09:00","quiet":true,"quiet_start":"00:00","quiet_end":"08:00"}';
        r jsonb := d; k text;
begin
  p := coalesce(p, '{}');
  foreach k in array array['orders','overdue','out','summary','swaps','coverage','tasks','cash','quiet'] loop
    if jsonb_typeof(p->k) = 'boolean' then r := jsonb_set(r, array[k], p->k); end if;
  end loop;
  if jsonb_typeof(p->'lead_hours') = 'number' then r := jsonb_set(r, '{lead_hours}', to_jsonb(least(greatest((p->>'lead_hours')::numeric::int, 1), 48))); end if;
  foreach k in array array['summary_time','quiet_start','quiet_end'] loop
    if coalesce(p->>k,'') ~ '^\d{1,2}:\d{2}$' then r := jsonb_set(r, array[k], to_jsonb(to_char((p->>k)::time, 'HH24:MI'))); end if;
  end loop;
  return r;
end $$;

create or replace function _push_collect(p_now timestamptz default now()) returns jsonb language plpgsql
set search_path = public, extensions as $$
declare tz text := 'America/New_York'; lnow timestamp := p_now at time zone tz; tnow time := lnow::time;
        today date := _shift_day_at(p_now); covered date;
        sub record; p jsonb; out jsonb := '[]'; tag text; k text; rc int;
        sup suppliers; nx timestamptz; n_low int;
        r record; ov_title text[]; ov_body text[]; os_title text[]; os_body text[];
        total int; done_n int; missed text[]; n_over int; n_out int; body text; st time; due_now boolean;
        endpoint_key text; quiet boolean; sw text[]; cv text[]; mgr boolean; nt text[]; nt_star boolean; nt_party int;
        cs text[]; n_short int; tol numeric := _cash_tolerance(); cash_line text;
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

    -- 8. a cash-out that's off by more than the tolerance (counting again sends a new alert if it's still off)
    if mgr and (p->>'cash')::boolean and not quiet then
      cs := '{}'; n_short := 0;
      for r in select c.id, c.drawer_name, c.diff, c.by_name, c.at, c.note from cashouts c
                where c.at > p_now - interval '24 hours' and c.at > sub.created_at - interval '1 hour' and abs(c.diff) > tol
                  and c.by_id is distinct from sub.staff_id
                order by c.at loop
        k := 'cash:' || endpoint_key || ':' || r.id || ':' || extract(epoch from r.at)::bigint;
        insert into push_sent(key) values (k) on conflict do nothing; get diagnostics rc = row_count;
        continue when rc = 0;
        if r.diff < 0 then n_short := n_short + 1; end if;
        cs := cs || (r.drawer_name || ' drawer ' || _cash_result(r.diff) || ' · ' || coalesce(r.by_name, 'someone') ||
                     case when r.note <> '' then '. “' || left(r.note, 80) || '”' else '' end);
      end loop;
      if array_length(cs, 1) = 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', case when n_short > 0 then 'Drawer came up short' else 'Drawer came up over' end, 'body', cs[1], 'url', './#cash', 'tag', 'cash');
      elsif array_length(cs, 1) > 1 then
        out := out || jsonb_build_object('endpoint', sub.endpoint, 'p256dh', sub.p256dh, 'auth', sub.auth,
          'title', array_length(cs, 1) || ' drawers off', 'body', array_to_string(cs, '. '), 'url', './#cash', 'tag', 'cash');
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
          -- cash: anything off, else all balanced (only once there are drawers)
          select case when count(*) = 0 then null
                      when count(*) filter (where abs(diff) > tol) = 0 then 'Cash balanced.'
                      else 'Cash: ' || string_agg(drawer_name || ' ' || _cash_result(diff), ', ' order by drawer_name) filter (where abs(diff) > tol) || '.' end
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
