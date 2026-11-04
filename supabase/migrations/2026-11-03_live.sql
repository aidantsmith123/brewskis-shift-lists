-- Version 49: live updates. After any save, the database tells every open copy of the app "something changed"
-- over Supabase Realtime (a public broadcast with no data in it), so phones reload within a second.
-- Safe to run more than once.

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
