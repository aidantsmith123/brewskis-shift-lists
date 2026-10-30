// Brewskis "calendar" Edge Function.
// Serves a person's shifts as a calendar subscription (iCalendar) for Google Calendar, Apple Calendar or Outlook.
//   GET /functions/v1/calendar?t=<private calendar token>          -> that person's shifts
//   GET /functions/v1/calendar?t=<manager's token>&all=1            -> the whole team's schedule
// The token is the only key, so each link is private to its person; resetting it in the app breaks the old link.
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 2 });
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

Deno.serve(async (req) => {
  if (req.method !== "GET" && req.method !== "HEAD") return new Response("Method not allowed", { status: 405 });
  const url = new URL(req.url);
  const token = (url.searchParams.get("t") || "").replace(/\.ics$/i, "");
  if (!UUID.test(token)) return new Response("Not found", { status: 404 });
  try {
    const [row] = await sql`select _calendar_ics(${token}::uuid, ${url.searchParams.get("all") === "1"}) as ics`;
    if (!row?.ics) return new Response("Not found", { status: 404 });
    return new Response(req.method === "HEAD" ? null : row.ics, {
      headers: {
        "Content-Type": "text/calendar; charset=utf-8",
        "Content-Disposition": 'inline; filename="jt-brewskis-shifts.ics"',
        "Cache-Control": "private, max-age=300",
      },
    });
  } catch (e) {
    console.error(e);
    return new Response("Server error", { status: 500 });
  }
});
