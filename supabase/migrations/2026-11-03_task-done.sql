-- Version 51: "Task done" notifications. When someone checks off a task a manager added, that manager is told
-- what got done and who did it (a new "Your tasks get done" switch, on by default). Safe to run more than once.

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
