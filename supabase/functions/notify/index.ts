// Brewskis "notify" Edge Function.
//   Every 15 minutes the database's scheduler calls this with its password (x-cron-secret).
//   It asks the database what's due (_push_collect) and sends each notification with Web Push.
//   The app also calls it with {test: true} to send a test notification to the manager's own phone.
// Signing keys and the scheduler password are read from the app_secrets table.
import webpush from "npm:web-push@3.6.7";
import postgres from "npm:postgres@3.4.5";

const sql = postgres(Deno.env.get("SUPABASE_DB_URL")!, { prepare: false, max: 2 });
const SITE = "https://aidantsmith123.github.io/brewskis-shift-lists/";
const cors = {
  "Access-Control-Allow-Origin": "*",
  "Access-Control-Allow-Headers": "content-type, apikey, authorization, x-client-info",
  "Access-Control-Allow-Methods": "POST, OPTIONS",
};
const json = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), { status, headers: { ...cors, "Content-Type": "application/json" } });

type Note = { endpoint: string; p256dh: string; auth: string; title: string; body: string; url?: string; tag?: string };

let secrets: Record<string, string> | null = null;
async function loadSecrets() {
  if (!secrets) {
    const rows = await sql`select name, value from app_secrets`;
    secrets = Object.fromEntries(rows.map((r) => [r.name, r.value]));
    webpush.setVapidDetails(SITE, secrets.vapid_public, secrets.vapid_private);
  }
  return secrets;
}

async function deliver(list: Note[]) {
  let sent = 0;
  const gone: string[] = [];
  const failed: string[] = [];
  for (const n of list) {
    const payload = JSON.stringify({ title: n.title, body: n.body, url: n.url ?? "./", tag: n.tag ?? "brewskis" });
    const sub = { endpoint: n.endpoint, keys: { p256dh: n.p256dh, auth: n.auth } };
    try {
      if (Deno.env.get("PUSH_DRY_RUN")) {
        webpush.generateRequestDetails(sub, payload, { TTL: 21600 }); // encrypts and signs, no network
      } else {
        await webpush.sendNotification(sub, payload, { TTL: 21600, urgency: "high" });
      }
      sent++;
    } catch (e) {
      const code = (e as { statusCode?: number }).statusCode;
      if (code === 404 || code === 410) gone.push(n.endpoint); // phone unsubscribed or app removed
      else failed.push(`${code ?? "error"}: ${(e as { body?: string }).body ?? String(e)}`);
    }
  }
  if (gone.length) await sql`select _push_forget(${gone}::text[])`;
  if (failed.length) console.error("push failures", failed);
  return { sent, removed: gone.length, failed: failed.length };
}

Deno.serve(async (req) => {
  if (req.method === "OPTIONS") return new Response(null, { headers: cors });
  if (req.method !== "POST") return json({ error: "method_not_allowed" }, 405);
  let body: Record<string, unknown> = {};
  try { body = await req.json(); } catch { /* empty body from the scheduler */ }
  try {
    const s = await loadSecrets();
    if (body.test) {
      const [row] = await sql`select _push_test(${String(body.token)}::uuid, ${String(body.endpoint)}) as n`;
      if (!row?.n) return json({ error: "not_found" }, 404);
      return json(await deliver([row.n as Note]));
    }
    if (!s.cron_secret || req.headers.get("x-cron-secret") !== s.cron_secret) return json({ error: "forbidden" }, 403);
    const [row] = await sql`select _push_collect() as list`;
    return json(await deliver((row?.list ?? []) as Note[]));
  } catch (e) {
    const msg = String((e as Error).message ?? e);
    if (msg.includes("not_logged_in")) return json({ error: "not_logged_in" }, 401);
    console.error(e);
    return json({ error: "server_error" }, 500);
  }
});
