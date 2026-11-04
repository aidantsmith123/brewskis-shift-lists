/* ---------- live updates ----------
   After every save, the database sends a "something changed" ping over Supabase Realtime (_live_ping in
   schema.sql). The ping carries no data: the app reloads its state through api_state like always, so nobody
   sees anything they couldn't before. Then it says who did what ("Jill checked off …") and flashes the rows
   that changed. If the connection drops it reconnects; the regular check keeps the app current either way. */
const LIVE = {ws:null, up:false, ref:0, joinRef:null, hb:null, hbWait:null, retry:0, retryTimer:null, wait:null, busy:false, again:false};
const LIVE_TOPIC = "realtime:brewskis-live";
function liveUrl(){
  if (CFG.realtimeUrl) return CFG.realtimeUrl;
  const u = new URL(CFG.supabaseUrl.replace(/\/$/,"") + "/realtime/v1/websocket");
  u.protocol = u.protocol==="http:" ? "ws:" : "wss:";
  u.search = "apikey="+encodeURIComponent(CFG.supabaseAnonKey)+"&vsn=1.0.0";
  return u.href;
}
function liveSend(topic, event, payload, joinRef){
  const ws = LIVE.ws; if (!ws || ws.readyState!==1) return null;
  const ref = String(++LIVE.ref);
  ws.send(JSON.stringify({topic, event, payload, ref, join_ref: joinRef===true ? ref : (joinRef || null)}));
  return ref;
}
function liveStart(){
  if (LIVE.ws || LIVE.retryTimer || !S.session || !configured() || document.hidden || !("WebSocket" in window)) return;
  let ws;
  try { ws = new WebSocket(liveUrl()); } catch(e){ return liveRetry(); }
  LIVE.ws = ws;
  ws.onopen = ()=>{
    if (LIVE.ws!==ws) return;
    LIVE.joinRef = liveSend(LIVE_TOPIC, "phx_join", {config:{broadcast:{ack:false, self:false}, presence:{enabled:false, key:""}, postgres_changes:[], private:false}}, true);
    clearInterval(LIVE.hb);
    LIVE.hb = setInterval(()=>{
      if (LIVE.hbWait){ try { ws.close(); } catch(e){} return; }   // the last heartbeat never came back: the line is dead
      LIVE.hbWait = liveSend("phoenix", "heartbeat", {});
    }, 25000);
  };
  ws.onmessage = e=>{
    if (LIVE.ws!==ws || typeof e.data!=="string") return;
    let m; try { m = JSON.parse(e.data); } catch(err){ return; }
    if (m.event==="phx_reply" && m.ref && m.ref===LIVE.hbWait){ LIVE.hbWait = null; return; }
    if (m.topic!==LIVE_TOPIC) return;
    if (m.event==="phx_reply" && m.ref===LIVE.joinRef){
      if (m.payload && m.payload.status==="ok"){
        const wasDown = LIVE.retry > 0;
        LIVE.up = true; LIVE.retry = 0;
        if (wasDown) liveChanged();   // catch up on anything missed while the connection was down
      } else { LIVE.retry = Math.max(LIVE.retry, 3); try { ws.close(); } catch(err){} }
      return;
    }
    if (m.event==="broadcast") liveChanged();
    else if (m.event==="phx_close" || m.event==="phx_error"){ try { ws.close(); } catch(err){} }
  };
  ws.onclose = ()=>{
    if (LIVE.ws!==ws) return;
    LIVE.ws = null; LIVE.up = false; LIVE.hbWait = null; clearInterval(LIVE.hb);
    liveRetry();
  };
  ws.onerror = ()=>{};   // onclose follows and handles it
}
function liveRetry(){
  clearTimeout(LIVE.retryTimer);
  if (!S.session || document.hidden) { LIVE.retryTimer = null; return; }
  const wait = [1000, 2000, 5000, 10000, 30000][Math.min(LIVE.retry, 4)];
  LIVE.retry++;
  LIVE.retryTimer = setTimeout(()=>{ LIVE.retryTimer = null; liveStart(); }, wait);
}
function liveStop(){
  clearTimeout(LIVE.retryTimer); LIVE.retryTimer = null; clearInterval(LIVE.hb);
  const ws = LIVE.ws; LIVE.ws = null; LIVE.up = false; LIVE.hbWait = null;
  if (ws) try { ws.close(); } catch(e){}
}
/* typing, choosing from a list, or mid-count: hold off redrawing the screen under someone's thumb */
function busyHands(){
  const a = document.activeElement;
  return !!((a && a.matches && a.matches("input,select,textarea")) || openDrop || Object.keys(S.countDraft||{}).length);
}
function liveChanged(){
  clearTimeout(LIVE.wait);
  LIVE.wait = setTimeout(liveRefresh, 500);   // a burst of saves becomes one reload
}
async function liveRefresh(){
  if (!S.session || document.hidden) return;
  if (busyHands()){ LIVE.wait = setTimeout(liveRefresh, 2000); return; }
  if (LIVE.busy){ LIVE.again = true; return; }
  LIVE.busy = true;
  try { await refresh({notice:true}); } finally { LIVE.busy = false; }
  if (LIVE.again){ LIVE.again = false; liveChanged(); }
}

/* ---------- what changed, and who did it ---------- */
function noticeChanges(prev, d){
  if (!prev || !prev.me || !d.me || prev.me.id!==d.me.id) return;
  const myId = d.me.id, had = new Set((prev.log||[]).map(l=>l.id)), now = Date.now();
  const fresh = activityEvents().filter(e=>!had.has(e.id) && e.whoId!==myId && now - new Date(e.at) < 120000);
  if (!fresh.length) return;
  liveToast(fresh);
  /* rows that changed because of someone else */
  const flash = new Set();
  const oldTasks = new Map((prev.tasks||[]).map(t=>[t.id, JSON.stringify(t)]));
  for (const t of d.tasks||[]){
    const was = oldTasks.get(t.id);
    if (was===JSON.stringify(t)) continue;
    if (was===undefined ? t.added_by===myId : t.done_by===myId) continue;
    flash.add("task:"+t.id);
  }
  const oldCounts = new Map((prev.counts||[]).map(c=>[c.item_id, c.counted_at+"|"+c.on_hand]));
  for (const c of d.counts||[]) if (c.counted_by!==myId && oldCounts.get(c.item_id)!==c.counted_at+"|"+c.on_hand) flash.add("item:"+c.item_id);
  const oldItems = new Map((prev.items||[]).map(i=>[i.id, i.on_tap]));
  for (const i of d.items||[]) if (oldItems.has(i.id) && oldItems.get(i.id)!==i.on_tap) flash.add("item:"+i.id);
  if (flash.size) S.fx.flash = flash;
}
let liveToastTimer = null;
function liveToast(events){
  let el = $("livetoast");
  if (!el){ el = h("div",{id:"livetoast", class:"livetoast", role:"status", "aria-live":"polite", hidden:true, onclick:()=>{ el.hidden = true; }}); document.body.append(el); }
  const e = events[0], others = events.length - 1;
  const first = (e.who||"Someone").trim();
  el.replaceChildren(
    h("span",{class:"lt-face", "aria-hidden":"true", text:first.charAt(0).toUpperCase()}),
    h("span",{class:"lt-text"}, h("b",{text:first.split(/\s+/)[0]}), e.what.replace(/^\s+/, " "),
      others ? h("span",{class:"lt-more", text:" · and "+others+" more"}) : null));
  el.hidden = false; el.classList.remove("show"); void el.offsetWidth; el.classList.add("show");
  clearTimeout(liveToastTimer); liveToastTimer = setTimeout(()=>{ el.hidden = true; }, 4500);
}
const flashing = key => !!(S.fx.flash && S.fx.flash.has(key));
