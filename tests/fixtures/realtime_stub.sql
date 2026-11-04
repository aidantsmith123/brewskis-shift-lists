-- Test-only stand-in for Supabase's realtime.send: hands the message to fake_postgrest.py through NOTIFY,
-- which passes it on to the app over its own websocket, the way Supabase Realtime would.
create schema if not exists realtime;
create table if not exists realtime.sent (id bigserial primary key, at timestamptz default clock_timestamp(), topic text, event text, payload jsonb);
create or replace function realtime.send(payload jsonb, event text, topic text, private boolean default true) returns void language plpgsql as $$
begin
  insert into realtime.sent (topic, event, payload) values (topic, event, payload);
  perform pg_notify('realtime', json_build_object('topic', topic, 'event', event, 'payload', payload)::text);
end $$;
grant usage on schema realtime to anon;
