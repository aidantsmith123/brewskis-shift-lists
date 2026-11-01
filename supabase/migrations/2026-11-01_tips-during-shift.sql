-- Version 37: card tips are pulled during the shift, not at close.
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run. Safe to run more than once.
-- At close the drawer is counted after tips are out: expected = bank + cash sales - card tips - paid outs; drop = counted - bank.

-- v37: card tips come out during the shift. Counts saved before that change are refigured the new way.
do $$
begin
  if not exists (select 1 from app_settings where name = 'cash_math_v37') then
    update cashouts set expected = bank + cash_sales - card_tips - paid_outs,
                        diff = counted - (bank + cash_sales - card_tips - paid_outs),
                        drop_amt = counted - bank;
    insert into app_settings (name, value) values ('cash_math_v37', 'true');
  end if;
end $$;

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
  expected := bank + sales - tips - pouts;
  select * into old from cashouts where day = d and drawer_id = dr.id for update;
  insert into cashouts (day, drawer_id, drawer_name, bank, cash_sales, card_tips, paid_outs, paid_out_note, bills, counted, expected, diff, drop_amt, note, by_id, by_name)
  values (d, dr.id, dr.name, bank, sales, tips, pouts, left(trim(coalesce(p_data->>'paid_out_note','')), 200), bills, counted, expected,
          counted - expected, counted - bank, left(trim(coalesce(p_data->>'note','')), 1000), me.id, me.name)
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
