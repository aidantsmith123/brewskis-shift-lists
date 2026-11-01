-- Version 39: party bookings only add the "Reply to party inquiry" task. Holds and bookings no longer add
-- deposit, headcount, party-day or thank-you tasks, and the open ones are cleared.
-- Paste this whole file into Supabase > SQL Editor > New query, then press Run. Safe to run more than once.

create or replace function _sync_party(p_id text, p_who_id text, p_who_name text) returns int language plpgsql
set search_path = public, extensions as $$
declare p parties; ev_id text; today date := _shift_day(); mrole text := _mgr_role(); n int := 0; i int; tk tasks;
        who text; dstr text; dep numeric; steps text[] := '{}'; dues date[] := '{}'; labels text[] := '{}';
begin
  select * into p from parties where id = p_id;
  if not found then return 0; end if;
  who := _short_name(p.host_name);
  dstr := coalesce(to_char(p.day, 'Dy Mon FMDD'), 'no date yet');

  -- the calendar: held and booked parties are on it
  if p.status in ('hold','booked') and p.day is not null then
    if p.event_id is not null and exists (select 1 from events where id = p.event_id) then
      update events set title = _party_title(p), kind = 'party', day = p.day, start_time = p.start_time, end_time = p.end_time,
                        repeat = 'none', repeat_until = null, skip_dates = '{}', updated_at = now()
       where id = p.event_id;
    else
      insert into events (title, kind, day, start_time, end_time, notes, added_by, added_by_name)
      values (_party_title(p), 'party', p.day, p.start_time, p.end_time, '', p_who_id, coalesce(p_who_name, 'Party booking'))
      returning id into ev_id;
      update parties set event_id = ev_id where id = p.id;
    end if;
  elsif p.event_id is not null then
    update parties set event_id = null where id = p.id;
    delete from events where id = p.event_id;
  end if;

  -- the tasks this party needs right now
  if p.status = 'inquiry' then
    steps := array['reply'];
    dues := array[coalesce(_shift_day_at(p.decided_at), _shift_day_at(p.submitted_at))];
    labels := array['Reply to party inquiry: ' || who || coalesce(' · ' || nullif(trim(p.occasion),''), '') || ' · ' || dstr ||
                    coalesce(' · ~' || p.guests || ' guests', '')];
  end if;

  delete from tasks where party_id = p.id and not done and not (party_step = any(steps));
  for i in 1 .. coalesce(array_length(steps, 1), 0) loop
    select * into tk from tasks where party_id = p.id and party_step = steps[i] limit 1;
    if found then
      if tk.due_date is distinct from dues[i] and dues[i] < today and steps[i] in ('confirm','setup','thanks') and not tk.done then
        delete from tasks where id = tk.id;
      elsif tk.due_date is distinct from dues[i] then
        update tasks set text = labels[i], due_date = dues[i], done = false, done_day = null, done_due = null, done_until = null,
                         done_by = null, done_by_name = null, done_at = null where id = tk.id;
      else
        update tasks set text = labels[i] where id = tk.id;
      end if;
    elsif dues[i] >= today or steps[i] in ('reply','deposit') then
      insert into tasks (role_id, text, repeat, due_date, important, added_by, added_by_name, party_id, party_step, added_at)
      values (mrole, labels[i], 'once', dues[i], true, p_who_id, coalesce(p_who_name, 'Party form'), p.id, steps[i], clock_timestamp());
      n := n + 1;
    end if;
  end loop;
  return n;
end $$;

-- v39: only inquiries get a task now; clear the open deposit, headcount, party-day and thank-you tasks.
delete from tasks where party_id is not null and party_step in ('deposit','confirm','setup','thanks') and not done;
