-- Upgrade: app version check-ins (shows managers who is on the latest version)
-- ---------- app versions (added Oct 2026) ----------
-- Each phone or computer reports which version of the app it's running when it opens and every few minutes after.
-- Managers see this on the Team tab to spot anyone who hasn't picked up the latest update.
create table if not exists app_devices (
  device_id text not null,
  staff_id text not null references staff(id) on delete cascade,
  version int not null,
  platform text not null default '',
  seen_at timestamptz not null default now(),
  primary key (device_id, staff_id)
);
do $$
begin
  alter table app_devices enable row level security;
  revoke all on table app_devices from public;
  if exists (select 1 from pg_roles where rolname='anon') then revoke all on table app_devices from anon; end if;
  if exists (select 1 from pg_roles where rolname='authenticated') then revoke all on table app_devices from authenticated; end if;
end $$;

create or replace function api_hello(p_token uuid, p_device text, p_version int, p_platform text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token);
begin
  if coalesce(p_device,'') !~ '^[A-Za-z0-9-]{8,64}$' or p_version is null then return; end if;
  insert into app_devices (device_id, staff_id, version, platform, seen_at)
  values (p_device, me.id, p_version, left(coalesce(p_platform,''), 40), now())
  on conflict (device_id, staff_id) do update set version = excluded.version, platform = excluded.platform, seen_at = now()
   where app_devices.version is distinct from excluded.version or app_devices.seen_at < now() - interval '5 minutes';
  delete from app_devices where seen_at < now() - interval '60 days';
end $$;

create or replace function api_versions(p_token uuid) returns json language plpgsql stable
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  return coalesce((select json_agg(json_build_object('staff_id', staff_id, 'device_id', device_id, 'version', version,
                                                     'platform', platform, 'seen_at', seen_at) order by seen_at desc)
                     from app_devices), '[]');
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
