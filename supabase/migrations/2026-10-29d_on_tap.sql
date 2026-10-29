-- Upgrade: on tap board
-- ---------- on tap board (added Oct 2026) ----------
-- Staff mark kegs as on tap or kicked; managers can set the name and style customers see.
-- api_on_tap() needs no login: it powers the public board (taps.html) and only returns what's on tap.
alter table items add column if not exists on_tap boolean not null default false;
alter table items add column if not exists tapped_at timestamptz;
alter table items add column if not exists tap_label text not null default '';
alter table items add column if not exists tap_note text not null default '';

create or replace function api_set_on_tap(p_token uuid, p_item_id text, p_on boolean) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _me(p_token); it items;
begin
  select * into it from items where id = p_item_id for update;
  if not found then raise exception 'not_found'; end if;
  if coalesce(p_on, false) = it.on_tap then return; end if;
  update items set on_tap = coalesce(p_on, false), tapped_at = case when p_on then now() else tapped_at end where id = p_item_id;
  perform _log(me, case when p_on then 'tapped' else 'kicked' end, coalesce(nullif(it.tap_label,''), it.name), 'Inventory');
end $$;

create or replace function api_set_tap_info(p_token uuid, p_item_id text, p_label text, p_note text) returns void language plpgsql
set search_path = public, extensions as $$
declare me staff := _mgr(p_token);
begin
  update items set tap_label = left(coalesce(trim(p_label),''), 60), tap_note = left(coalesce(trim(p_note),''), 80) where id = p_item_id;
  if not found then raise exception 'not_found'; end if;
end $$;

create or replace function api_on_tap() returns json language sql stable
set search_path = public, extensions as $$
  select json_build_object(
    'updated_at', now(),
    'taps', coalesce((select json_agg(json_build_object(
              'name', coalesce(nullif(tap_label,''), trim(regexp_replace(name, '\s+(1/2|1/4|1/6|50L|30L|20L|sixtel|half|keg)$', '', 'i'))),
              'note', tap_note,
              'tapped_at', tapped_at) order by coalesce(nullif(tap_label,''), name))
            from items where on_tap), '[]'))
$$;

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
    'log', coalesce((select json_agg(x order by x.at desc) from (
        select id, at, who, who_name, kind, text, place from log
         where mgr or kind <> 'ordered' order by at desc limit 1000) x), '[]')
  );
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
