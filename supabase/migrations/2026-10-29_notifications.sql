-- Upgrade: manager notifications (order deadlines, overdue tasks, out of stock, nightly recap)
-- The signing keys and scheduler password are added separately (see README) so they never land in GitHub.

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

-- ---------- run the "notify" Edge Function every 15 minutes ----------
create extension if not exists pg_cron;
create extension if not exists pg_net;
select cron.schedule('brewskis-notify', '*/15 * * * *', $cron$
  select net.http_post(
    url := 'https://xlvukvolpmsgyhtvbtut.supabase.co/functions/v1/notify',
    headers := jsonb_build_object('Content-Type', 'application/json',
                                  'x-cron-secret', (select value from public.app_secrets where name = 'cron_secret')),
    body := '{}'::jsonb,
    timeout_milliseconds := 30000)
$cron$);
