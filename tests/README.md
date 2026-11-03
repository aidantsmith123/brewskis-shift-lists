# Browser tests

Each `e2e_*.py` file drives the app in a headless Chromium (Playwright) the way a person would: logging in,
tapping through screens, and checking what shows up, against a local copy of the database.

## What you need

- PostgreSQL 16, running on a socket in `/var/tmp`, port `54329` (no password for `postgres`)
- Python 3 with `playwright` and `psycopg`, plus Playwright's Chromium

## Running them

```bash
# 1. the local stand-in for Supabase's API, serving the app from site/
python3 tests/fake_postgrest.py site 8099 &

# 2. every suite, each on the database setup it expects
bash tests/run_all.sh /tmp/brewskis-e2e
```

`run_all.sh` prints `pass` or `FAIL` per suite and a summary; a failed suite's output is in its `.log` file.
To run one suite: set up the database (`bash tests/setup_v22.sh` for most; see the top of `run_all.sh` for the others),
then `python3 tests/e2e_parties.py /tmp/brewskis-e2e`.

## The test data

- `reset_db.sh` builds the database the way the live one grew: `fixtures/schema_v1.sql` and `fixtures/seed.sql`,
  then today's `supabase/schema.sql` on top. Test login numbers: Aidan 4821, Jill 1111.
- `setup_v22.sh` does that, clears the old checklists, and adds Kate (2222, closing bartender) and Liam (5555, dishwasher).
- `fixtures/v8_state.sql` adds the liquor list a few inventory suites use.

The login numbers here are for the test database only. None of them is a real login number.

Dates come from today, so the suites pass on any day. Sending a real push notification needs the live Edge Function
and isn't covered.
