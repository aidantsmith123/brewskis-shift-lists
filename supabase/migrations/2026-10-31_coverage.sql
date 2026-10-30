-- Version 21: shift coverage.
--  * Anyone can ask for coverage, even for a shift that isn't on the schedule yet.
--  * Every employee can turn on notifications: they hear right away when a shift they could work needs coverage,
--    and when someone covers it. Managers keep their other alerts.
-- Safe to run more than once.

alter table shifts add column if not exists posted_by text;
alter table shifts add column if not exists created_by text;

create or replace function _fmt_shift_role(p_start timestamptz, p_end timestamptz, p_role text) returns text language sql stable as $$
  select _fmt_shift(p_start, p_end) || coalesce(' (' || (select name from roles where id = p_role) || ')', '')
$$;

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

create or replace function _shift_json(s shifts) returns json language sql stable as $$
  select json_build_object('id', s.id, 'staff_id', s.staff_id, 'role_id', s.role_id, 'start_at', s.start_at, 'end_at', s.end_at,
                           'note', s.note, 'up_for_grabs', s.up_for_grabs, 'posted_at', s.posted_at, 'posted_note', s.posted_note,
                           'posted_by', s.posted_by, 'created_by', s.created_by)
$$;

create or replace function _push_prefs(p jsonb) returns jsonb language plpgsql immutable as $$
declare d jsonb := '{"orders":true,"lead_hours":2,"overdue":true,"out":true,"summary":true,"swaps":true,"coverage":true,"summary_time":"09:00","quiet":true,"quiet_start":"00:00","quiet_end":"08:00"}';
        r jsonb := d; k text;
begin
  p := coalesce(p, '{}');
  foreach k in array array['orders','overdue','out','summary','swaps','coverage','quiet'] loop
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
        endpoint_key text; quiet boolean; sw text[]; cv text[]; mgr boolean;
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

create or replace function api_push_save(p_token uuid, p_endpoint text, p_p256dh text, p_auth text, p_prefs jsonb) returns jsonb language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); pr jsonb := _push_prefs(p_prefs);
begin
  if coalesce(p_endpoint,'') !~ '^https://' or coalesce(p_p256dh,'') = '' or coalesce(p_auth,'') = '' then raise exception 'bad_subscription'; end if;
  insert into push_subs (endpoint, staff_id, p256dh, auth, prefs) values (p_endpoint, me.id, p_p256dh, p_auth, pr)
  on conflict (endpoint) do update set staff_id = me.id, p256dh = excluded.p256dh, auth = excluded.auth, prefs = excluded.prefs, updated_at = now();
  return pr;
end $$;

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
    'log', coalesce((select json_agg(x order by x.at desc) from (
        select id, at, who, who_name, kind, text, place from log
         where mgr or kind <> 'ordered' order by at desc limit 1000) x), '[]')
  );
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

create or replace function api_delete_shift(p_token uuid, p_id text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); s shifts;
begin
  select * into s from shifts where id = p_id;
  if not found then return; end if;
  if not _is_manager(me.roles) and not (s.created_by = me.id and s.staff_id = me.id) then raise exception 'managers_only'; end if;
  delete from shifts where id = p_id;
end $$;

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
