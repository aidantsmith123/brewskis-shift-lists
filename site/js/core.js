/* JT Brewski's staff app — PWA front end. Talks to Supabase only through the api_* database functions.
   The app is split across the files in site/js/, loaded in order by index.html (core.js first, main.js last).
   They share one global scope, so anything a file runs right away may only use what earlier files define. */
"use strict";

const CFG = window.BREWSKIS_CONFIG || {};
/* The app's version. Bump this, site/version.json and VERSION in site/sw.js together with every release. */
const APP_VERSION = 49;
const APP_DATE = "2026-11-03";
const ROLL_HOUR = 5;
const SESSION_KEY = "brewskis.session";
const CACHE_KEY = "brewskis.state";
const POLL_MS = 15000;
const SECTIONS = [["mgmt","Management","Mgr"],["foh","Front of house","FOH"],["boh","Back of house","BOH"]];
const secInfo = s => SECTIONS.find(x=>x[0]===s) || [s, s, s];
const DAYS = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
const INV_STARTERS = {
  "bar-supplies":[["Limes","cases"],["Lemons","cases"],["Oranges","cases"],["Maraschino cherries","jars"],["Olives","jars"],["Sour mix","bottles"],["Simple syrup","bottles"],["Grenadine","bottles"],["Bloody Mary mix","bottles"],["Bar towels","bundles"],["CO2 tanks","tanks"],["Sanitizer","gallons"]],
  "paper-products":[["Beverage napkins","cases"],["Dinner napkins","cases"],["Straws","boxes"],["Stir sticks","boxes"],["Coasters","boxes"],["Paper towels","cases"],["Toilet paper","cases"],["To-go containers","cases"],["To-go bags","packs"],["Plastic cutlery kits","cases"],["Receipt paper","boxes"],["Trash bags","cases"]]
};

const S = {
  session:null, data:null, dataAt:null, offline:!navigator.onLine, booting:true,
  view:"overview", roleId:null, filter:"all", invFilter:"all", invEdit:false, confirm:null,
  draft:{text:"", assignee:"", repeat:"once", due_date:"", due_time:"", role_id:"", important:false}, taskFilter:"all", addingTask:false, showDone:false, editTask:null, editDraft:null, newPerson:"", newRole:"", newRoleSection:"foh",
  newItem:{}, newCat:"", newSup:{name:"", days:[], cutoff:"14:00", notes:"", schedule:"weekly", start_date:""},
  countDraft:{}, countTimers:{}, actQuery:"", actRange:"all", actLimit:10,
  pin:"", loginErr:"", loginBusy:false, lockUntil:0, pinEdit:null, pinDraft:"", pinErr:"", pinBusy:false,
  invQuery:"", invSup:null, open:loadOpen(), fx:{}, week:null, weekCache:{}, evMonth:null, evDay:null,
  latest:null, versions:null, versionsAt:0, helloAt:0, updating:false,
  installEvent:null, push:{loaded:false, sub:null, prefs:null, busy:false, err:""}
};

/* ---------- API ---------- */
function configured(){ return CFG.supabaseUrl && !/YOUR-PROJECT/.test(CFG.supabaseUrl) && CFG.supabaseAnonKey && !/YOUR-ANON/.test(CFG.supabaseAnonKey); }
async function rpc(fn, args){
  let res;
  try {
    res = await fetch(CFG.supabaseUrl.replace(/\/$/,"") + "/rest/v1/rpc/" + fn, {
      method:"POST",
      headers: Object.assign({"Content-Type":"application/json", "apikey":CFG.supabaseAnonKey},
        /^eyJ/.test(CFG.supabaseAnonKey) ? {"Authorization":"Bearer "+CFG.supabaseAnonKey} : {}), // legacy anon keys are JWTs; new publishable keys go in apikey only
      body:JSON.stringify(args||{})
    });
  } catch(e){ setOffline(true); const err = new Error("offline"); err.code = "offline"; throw err; }
  setOffline(false);
  const text = await res.text(); let body = null;
  try { body = text ? JSON.parse(text) : null; } catch(e){}
  if (!res.ok){ const err = new Error((body && body.message) || "error"); err.code = (body && body.message) || "error"; throw err; }
  return body;
}
const call = (fn, args) => rpc(fn, Object.assign({p_token:S.session && S.session.token}, args||{}));

function errMsg(e){
  const c = e && e.code;
  return ({
    offline:"You're offline. Try again when you're back on Wi-Fi or data.",
    managers_only:"Only managers can do that.",
    last_manager:"Keep at least one manager who can log in.",
    number_taken:"That number is already taken. Pick another.",
    bad_number:"Use 4 to 6 digits.",
    empty:"Type something first.",
    not_found:"That was already removed.",
    shift_gone:"Someone already took that shift.",
    not_your_role:"That shift needs a role you don't have.",
    overlaps:"You're already working during that shift.",
    shift_started:"That shift has already started.",
    bad_time:"Check the date, start and end times.",
    bad_amount:"Check the amount.",
    use_party:"This is a party booking. Change it from the booking.",
    bad_status:"Couldn't change that. Try again.",
    foh_only:"Only front-of-house staff and managers can cash out.",
    need_amount:"Enter how much it's short.",
    pick_area:"Pick front of house or back of house.",
    not_allowed:"Only Aidan, Tom and Mandy can do that.",
    need_numbers:"Enter the cash sales and the COH.",
    need_payee:"Add who each payout went to.",
    too_many:"That's a lot of alerts in a few minutes. Try again shortly.",
    name_taken:"There's already a drawer with that name."
  })[c] || "Couldn't save. Try again in a moment.";
}
/* run an action, then pull fresh data; returns true when it worked */
async function act(fn, args, okMsg){
  if (S.offline){ toast(errMsg({code:"offline"})); return false; }
  try { await call(fn, args); }
  catch(e){
    if (e.code==="not_logged_in"){ logOut("You've been logged out. Enter your number again."); return false; }
    play("nope"); toast(errMsg(e)); refresh(); return false;
  }
  if (okMsg) toast(okMsg);
  await refresh();
  return true;
}
async function refresh(opts){
  if (!S.session) return;
  try {
    const d = await call("api_state"), prev = S.data;
    S.data = d; S.dataAt = new Date().toISOString(); S.weekCache = {}; S.refreshedAt = Date.now();
    if (opts && opts.notice) try { noticeChanges(prev, d); } catch(e){}
    sayHello();
    if (S.view==="team" && Date.now() - S.versionsAt > 60000) loadVersions();
    try { localStorage.setItem(CACHE_KEY, JSON.stringify({token:S.session.token, at:S.dataAt, data:d})); } catch(e){}
  } catch(e){
    if (e.code==="not_logged_in"){ logOut("You've been logged out. Enter your number again."); return; }
  }
  S.booting = false;
  render();
}
/* ---------- sections that open and close (remembered on this phone) ---------- */
function loadOpen(){ try { return JSON.parse(localStorage.getItem("brewskis.open") || "{}") || {}; } catch(e){ return {}; } }
function isOpen(key, byDefault){ return key in S.open ? !!S.open[key] : byDefault; }
function toggleOpen(key, byDefault){
  S.open[key] = !isOpen(key, byDefault);
  try { localStorage.setItem("brewskis.open", JSON.stringify(S.open)); } catch(e){}
  S.fx.fold = key;
  render();
}
/* a section with a tappable header; `forced` keeps it open while a search or filter is showing matches */
function fold(key, byDefault, title, badge, body, opts={}){
  const open = opts.forced || isOpen(key, byDefault);
  const id = "fold-" + key.replace(/[^A-Za-z0-9]/g, "-");
  return h("section",{class:"fold"+(open?" open":"")+(opts.forced?" forced":"")},
    h("button",{type:"button", class:"fold-head", id:id+"-head", "aria-expanded":String(open), "aria-controls":id, disabled:!!opts.forced,
        onclick:()=>toggleOpen(key, byDefault)},
      h("span",{class:"chev", "aria-hidden":"true"}),
      h("h2",{class:opts.titleClass||"", text:title}),
      badge || null),
    open ? h("div",{class:"fold-body stack"+(S.fx.fold===key ? " reveal" : ""), id}, body) : null);
}
/* does an item match the inventory search? every word has to appear in its name or unit */
function matchesQuery(it, q){
  if (!q) return true;
  const hay = (it.name+" "+(it.unit||"")).toLowerCase();
  return q.split(/\s+/).every(w=>hay.includes(w));
}

/* ---------- app versions ---------- */
function deviceId(){
  try {
    let id = localStorage.getItem("brewskis.device");
    if (!id){ id = (crypto.randomUUID ? crypto.randomUUID() : Array.from(crypto.getRandomValues(new Uint8Array(16)), b=>b.toString(16).padStart(2,"0")).join("")); localStorage.setItem("brewskis.device", id); }
    return id;
  } catch(e){ return null; }
}
function platformLabel(){
  const ua = navigator.userAgent;
  const dev = (/iPad/.test(ua) || (navigator.platform==="MacIntel" && navigator.maxTouchPoints>1)) ? "iPad" : /iPhone|iPod/.test(ua) ? "iPhone"
            : /Android/.test(ua) ? "Android" : /Mac/.test(ua) ? "Mac" : /Windows/.test(ua) ? "Windows PC" : "Computer";
  return dev + (isStandalone() ? " app" : " browser");
}
/* tell the server which version this device is running (at most every 5 minutes) */
function sayHello(){
  if (!S.session || Date.now() - S.helloAt < 300000) return;
  const id = deviceId(); if (!id) return;
  S.helloAt = Date.now();
  call("api_hello",{p_device:id, p_version:APP_VERSION, p_platform:platformLabel()}).catch(()=>{ S.helloAt = 0; });
}
/* what's the newest version published? */
let latestAt = 0;
async function checkLatest(force){
  if (!force && Date.now() - latestAt < 300000) return;
  latestAt = Date.now();
  try {
    const r = await fetch("version.json?t="+Date.now(), {cache:"no-store"});
    if (r.ok){ const v = await r.json(); if (v && Number(v.version)){ S.latest = v; render(); } }
  } catch(e){}
}
const latestVersion = () => Math.max(APP_VERSION, Number(S.latest && S.latest.version) || 0);
const updateReady = () => !!S.latest && Number(S.latest.version) > APP_VERSION;
function fmtVersionDate(str){ return str ? parseDay(str).toLocaleDateString(undefined,{month:"short", day:"numeric", year:"numeric"}) : ""; }
async function applyUpdate(auto){
  if (S.updating) return;
  S.updating = true; render();
  try { sessionStorage.setItem("brewskis.updated", String(S.latest ? S.latest.version : "")); sessionStorage.setItem("brewskis.intro", "1"); sessionStorage.setItem("brewskis.view", S.view==="notify" ? "settings" : S.view); } catch(e){}
  try {
    const reg = "serviceWorker" in navigator ? await navigator.serviceWorker.getRegistration() : null;
    if (reg){
      const changed = new Promise(res=>{ navigator.serviceWorker.addEventListener("controllerchange", res, {once:true}); setTimeout(res, 6000); });
      await reg.update();
      if (reg.installing || reg.waiting) await changed;
    }
  } catch(e){}
  location.reload();
}
async function loadVersions(){
  if (!isAdmin()) return;
  S.versionsAt = Date.now();
  try { S.versions = await call("api_versions"); render(); } catch(e){}
}
function versionLine(){
  const ready = updateReady();
  return h("div",{class:"vline"+(ready?" behind":"")},
    h("span",{text:"App version "+APP_VERSION+" · "+fmtVersionDate(APP_DATE)}),
    ready ? h("span",{class:"tag warn", text:"Version "+S.latest.version+" is ready"}) : S.latest ? h("span",{class:"tag ok", text:"Up to date"}) : null);
}
/* Updates install themselves when nobody's in the middle of something: when the app is opened or brought back,
   or after a minute without a tap. Never with a form open, something typed, a list open or counts still saving. */
let lastTouch = Date.now();
["pointerdown","keydown","touchstart","wheel"].forEach(t=>addEventListener(t, ()=>{ lastTouch = Date.now(); }, {passive:true, capture:true}));
function safeToUpdate(){
  const a = document.activeElement;
  return updateReady() && !S.updating && !S.offline && !document.hidden && $("sheet").hidden && !openDrop &&
    !(a && a.matches && a.matches("input,select,textarea")) && !Object.keys(S.countDraft||{}).length &&
    !S.addingTask && !S.editTask && !S.pin;
}
/* one automatic try per version per session: if the new files didn't arrive, don't keep reloading (the bar stays) */
function autoUpdate(idleMs){
  if (!safeToUpdate() || Date.now() - lastTouch < (idleMs||0)) return;
  const v = String(S.latest.version);
  try { if (sessionStorage.getItem("brewskis.autoTried")===v) return; sessionStorage.setItem("brewskis.autoTried", v); } catch(e){ return; }
  applyUpdate(true);
}
setInterval(()=>autoUpdate(60000), 15000);
document.addEventListener("visibilitychange", async ()=>{
  if (document.hidden) return;
  await checkLatest(Date.now() - latestAt > 60000);
  autoUpdate(0);
});
function setOffline(v){ if (S.offline!==v){ S.offline = v; renderOffline(); } }

/* ---------- session ---------- */
function loadSession(){ try { const v = localStorage.getItem(SESSION_KEY); return v ? JSON.parse(v) : null; } catch(e){ return null; } }
function storeSession(s){ try { s ? localStorage.setItem(SESSION_KEY, JSON.stringify(s)) : localStorage.removeItem(SESSION_KEY); } catch(e){} }
function logOut(msg){
  const tok = S.session && S.session.token;
  S.session = null; S.data = null; storeSession(null); if (typeof liveStop==="function") liveStop();
  try { localStorage.removeItem(CACHE_KEY); } catch(e){}
  if (tok) rpc("api_logout", {p_token:tok}).catch(()=>{});
  S.view = "overview"; S.invEdit = false; S.pin = "";
  document.getElementById("sheet").hidden = true;
  if (msg) toast(msg);
  render();
}

/* ---------- pick-lists: a compact field that opens into buttons ----------
   Every <select> in the app shows as one field with the current choice and a ▾. Tapping it opens the choices right
   underneath as buttons; picking one closes it again. The select stays in the page, hidden, so the code that builds it,
   reads .value or listens for "change" works the same. */
const nativeValue = Object.getOwnPropertyDescriptor(HTMLSelectElement.prototype, "value");
let openDrop = null;
function closeDrop(){ if (openDrop){ const d = openDrop; openDrop = null; d(); } }
function buttonize(sel){
  if (sel._pick || sel.dataset.native) return;
  let open = false;
  const cur = h("span",{class:"dv"}), btn = h("button",{type:"button", class:"dropbtn", "aria-expanded":"false"}, cur, h("span",{class:"dchev", "aria-hidden":"true"}));
  const list = h("div",{class:"btnpick", role:"radiogroup", hidden:true});
  const wrap = h("div",{class:"drop"}, btn, list);
  const lbl = sel.closest("label"); if (lbl){ const t = (lbl.firstChild && lbl.firstChild.nodeType===3 ? lbl.firstChild.textContent : "").trim(); if (t){ list.setAttribute("aria-label", t); btn.setAttribute("aria-label", t); } }
  const setOpen = v => {
    if (v && openDrop && openDrop !== shut) closeDrop();
    open = v; openDrop = v ? shut : (openDrop===shut ? null : openDrop);
    list.hidden = !v; btn.setAttribute("aria-expanded", String(v)); wrap.classList.toggle("open", v);
    if (v){
      const c = list.querySelector('[aria-checked="true"]') || list.querySelector("button"); if (c) c.focus({preventScroll:true});
      /* bring the opened list to the middle of the screen (or its top, if it's taller than the screen) */
      requestAnimationFrame(()=>{
        const tall = wrap.getBoundingClientRect().height > window.innerHeight * 0.75;
        const calm = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
        wrap.scrollIntoView({block: tall ? "start" : "center", behavior: calm ? "auto" : "smooth"});
      });
    }
  };
  const shut = () => setOpen(false);
  btn.addEventListener("click", e=>{ e.preventDefault(); setOpen(!open); });
  const draw = () => {
    wrap.hidden = sel.hidden;
    const v = nativeValue.get.call(sel), o = [...sel.options].find(x=>x.value===v) || sel.options[0];
    cur.textContent = o ? o.textContent : "";
    btn.disabled = sel.disabled;
    list.replaceChildren(...[...sel.options].map(o=>h("button",{type:"button", role:"radio", "aria-checked":String(o.value===v),
      disabled: sel.disabled || o.disabled, "data-value":o.value, onclick:e=>{
        e.preventDefault(); setOpen(false); btn.focus({preventScroll:true});
        if (o.value===nativeValue.get.call(sel)) return;
        nativeValue.set.call(sel, o.value); draw();
        sel.dispatchEvent(new Event("input",{bubbles:true})); sel.dispatchEvent(new Event("change",{bubbles:true}));
      }}, o.textContent)));
  };
  /* code that sets .value directly, or swaps the options, redraws it */
  Object.defineProperty(sel, "value", {configurable:true, get(){ return nativeValue.get.call(sel); }, set(v){ nativeValue.set.call(sel, v); draw(); }});
  new MutationObserver(draw).observe(sel, {childList:true, subtree:true, attributes:true, attributeFilter:["disabled","selected","hidden"]});
  sel.addEventListener("change", draw);
  sel._pick = wrap; sel.classList.add("picked"); sel.setAttribute("aria-hidden","true"); sel.tabIndex = -1;
  sel.after(wrap); draw();
}
/* tap anywhere else, or press Escape, to close an open list */
document.addEventListener("click", e=>{ if (openDrop && !(e.target.closest && e.target.closest(".drop.open"))) closeDrop(); }, true);
document.addEventListener("keydown", e=>{ if (e.key==="Escape" && openDrop){ closeDrop(); e.stopPropagation(); } }, true);
new MutationObserver(muts=>{ for (const m of muts) for (const n of m.addedNodes){
  if (n.nodeType!==1) continue;
  if (n.tagName==="SELECT") buttonize(n); else if (n.querySelectorAll) n.querySelectorAll("select").forEach(buttonize);
} }).observe(document.documentElement, {childList:true, subtree:true});

/* ---------- helpers ---------- */
function h(tag, props, ...kids){
  const el = document.createElement(tag);
  for (const [k,v] of Object.entries(props||{})){
    if (v==null || v===false) continue;
    if (k==="class") el.className = v;
    else if (k==="text") el.textContent = v;
    else if (k.startsWith("on")) el.addEventListener(k.slice(2), v);
    else if (k==="value"||k==="checked"||k==="disabled"||k==="selected") el[k] = v;
    else el.setAttribute(k, v===true ? "" : v);
  }
  for (const c of kids.flat(Infinity)){ if (c==null||c===false) continue; el.append(c.nodeType ? c : document.createTextNode(String(c))); }
  return el;
}
const $ = id => document.getElementById(id);
const pad = n => String(n).padStart(2,"0");
const fmtN = n => n==null ? "–" : (Number.isInteger(n) ? String(n) : String(Math.round(n*10)/10));
function shiftDay(d=new Date()){ const x = new Date(d.getTime() - ROLL_HOUR*3600e3); return x.getFullYear()+"-"+pad(x.getMonth()+1)+"-"+pad(x.getDate()); }
function shiftStartISO(){ const [y,m,d] = shiftDay().split("-").map(Number); return new Date(y, m-1, d, ROLL_HOUR).toISOString(); }
function when(iso){
  if (!iso) return ""; const d = new Date(iso); const now = new Date();
  const t = d.toLocaleTimeString(undefined,{hour:"numeric",minute:"2-digit"});
  return d.toDateString()===now.toDateString() ? t : d.toLocaleDateString(undefined,{month:"short",day:"numeric"})+", "+t;
}
function initials(n){ return (n||"?").trim().split(/\s+/).map(s=>s[0]).slice(0,2).join("").toUpperCase() || "?"; }
const D = () => S.data || {roles:[], staff:[], tasks:[], invcats:[], items:[], counts:[], suppliers:[], shifts:[], covers:[], events:[], parties:[], settings:{}, drawers:[], cashouts:[], alerts:[], daily_cash:[], log:[], me:null};
const me = () => D().me;
const isAdmin = () => !!(me() && me().manager);
const canWrite = () => !!me() && !S.offline;
const roleById = id => D().roles.find(r=>r.id===id);
const roleName = id => (roleById(id)||{}).name || "";
const staffById = id => D().staff.find(s=>s.id===id);
const isManagerStaff = s => !!s && (s.roles||[]).some(id=>(roleById(id)||{}).section==="mgmt");
/* ---------- task schedules ---------- */
const REPEATS = [["once","Just once"],["daily","Every day"],["weekly","Weekly"],["biweekly","Every 2 weeks"],["monthly","Monthly"]];
const RECURRING = new Set(["weekly","biweekly","monthly"]);
function parseDay(str){ const [y,m,d] = str.split("-").map(Number); return new Date(y, m-1, d); }
function addDays(str, n){ const d = parseDay(str); d.setDate(d.getDate()+n); return d.getFullYear()+"-"+pad(d.getMonth()+1)+"-"+pad(d.getDate()); }
/* when a task is due: with no time it's due by the end of that shift day (5 AM); times before 5 AM count as late that same shift day */
function deadlineOf(dateStr, timeStr){
  if (!dateStr) return null;
  const [y,m,d] = dateStr.split("-").map(Number);
  if (!timeStr) return new Date(y, m-1, d+1, ROLL_HOUR, 0);
  const [hh,mm] = timeStr.split(":").map(Number);
  return hh < ROLL_HOUR ? new Date(y, m-1, d+1, hh, mm) : new Date(y, m-1, d, hh, mm);
}
const hhmm = t => t ? String(t).slice(0,5) : "";
function fmtClock(t){ const [h,m] = hhmm(t).split(":").map(Number); return new Date(2000,0,1,h,m).toLocaleTimeString(undefined,{hour:"numeric",minute:"2-digit"}); }
function fmtDue(dateStr){
  const today = shiftDay(); if (dateStr===today) return "today"; if (dateStr===addDays(today,1)) return "tomorrow";
  const d = parseDay(dateStr), diff = Math.round((d - parseDay(today))/86400e3);
  if (diff > 1 && diff < 7) return d.toLocaleDateString(undefined,{weekday:"short"});
  return d.toLocaleDateString(undefined,{weekday:"short", month:"short", day:"numeric"});
}
function ordinal(n){ const s = ["th","st","nd","rd"], v = n % 100; return n + (s[(v-20)%10] || s[v] || s[0]); }
function repeatLabel(t){
  const wd = t.due_date ? parseDay(t.due_date).toLocaleDateString(undefined,{weekday:"short"}) : "";
  return ({daily:"Daily", weekly:"Weekly · "+wd, biweekly:"Every 2 weeks · "+wd, monthly:"Monthly · "+ordinal(t.anchor_day || (t.due_date ? parseDay(t.due_date).getDate() : 1)), once:"One-time"})[t.repeat] || "Daily";
}
function isDone(t){
  if (t.repeat==="daily") return t.done_day===shiftDay();
  if (RECURRING.has(t.repeat)) return !!t.done_until && new Date(t.done_until) > new Date();
  return !!t.done;
}
function taskDeadline(t){ return t.repeat==="daily" ? (t.due_time ? deadlineOf(shiftDay(), hhmm(t.due_time)) : null) : deadlineOf(t.due_date, hhmm(t.due_time)); }
const isOverdue = t => !isDone(t) && !!taskDeadline(t) && new Date() > taskDeadline(t);
/* "now" = on today's list, "later" = coming up, "done" */
function bucket(t){
  if (isDone(t)) return "done";
  if (t.repeat==="daily" || !t.due_date) return "now";
  return t.due_date <= shiftDay() ? "now" : "later";
}
/* what counts toward today's progress: everything due today or overdue, plus anything finished during today's shift */
function countsToday(t){
  const b = bucket(t);
  if (b==="now") return true;
  if (b==="done") return t.repeat==="daily" || (!!t.done_at && new Date(t.done_at) >= new Date(shiftStartISO()));
  return false;
}
function dueLine(t){
  if (isDone(t)){
    if (RECURRING.has(t.repeat) && t.due_date) return {cls:"", text:"Next due "+fmtDue(t.due_date)+(t.due_time?" by "+fmtClock(t.due_time):"")};
    return null;
  }
  if (t.repeat==="daily") return t.due_time ? {cls:isOverdue(t)?"over":"", text:(isOverdue(t)?"Overdue · was due by ":"Due by ")+fmtClock(t.due_time)} : null;
  if (!t.due_date) return null;
  const when = fmtDue(t.due_date) + (t.due_time ? " by "+fmtClock(t.due_time) : "");
  if (isOverdue(t)) return {cls:"over", text:"Overdue · was due "+when};
  return {cls: t.due_date===shiftDay() ? "soon" : "", text:"Due "+when};
}
function secIdx(s){ const i = SECTIONS.findIndex(x=>x[0]===s); return i<0 ? 9 : i; }
function sortedRoles(sec){ return D().roles.filter(r=>!sec||r.section===sec).sort((a,b)=>secIdx(a.section)-secIdx(b.section)||(a.sort||0)-(b.sort||0)||a.name.localeCompare(b.name)); }
const roleTasks = id => D().tasks.filter(t=>t.role_id===id);
const roleStaff = id => D().staff.filter(s=>(s.roles||[]).includes(id));
const staffName = id => (staffById(id)||{}).name || "Former staff";

/* inventory */
const catItems = id => D().items.filter(i=>i.cat_id===id);
const countOf = id => D().counts.find(c=>c.item_id===id);
function onHandOf(it){ if (it.id in S.countDraft) return S.countDraft[it.id]; const c = countOf(it.id); return c ? Number(c.on_hand) : null; }
function parOf(it){ return it.par==null ? null : Number(it.par); }
function needOf(it){ const oh = onHandOf(it), par = parOf(it); return (par!=null && oh!=null) ? Math.max(0, par - oh) : null; }
function statusOf(it){
  const oh = onHandOf(it), par = parOf(it);
  if (par==null) return {cls:"plain", text:"No par set"};
  if (oh==null) return {cls:"plain", text:"Not counted"};
  if (oh<=0) return {cls:"danger", text:"Out · order "+fmtN(par)};
  if (par-oh>0) return {cls:"warn", text:"Order "+fmtN(par-oh)};
  return {cls:"ok", text:"At par"};
}
const supplierById = id => D().suppliers.find(s=>s.id===id);
/* ---------- supplier order schedules ---------- */
const SUP_SCHEDULES = [["weekly","Weekly"],["biweekly","Every 2 weeks"],["daily","Every day"],["monthly","Monthly"],["once","One time"]];
const NEEDS_START = new Set(["biweekly","monthly","once"]);
function atCutoff(day, cutoff){ const [hh,mm] = (cutoff||"14:00").split(":").map(Number); const d = new Date(day.getFullYear(), day.getMonth(), day.getDate()); d.setHours(hh||0, mm||0, 0, 0); return d; }
function shiftDays(day, n){ return new Date(day.getFullYear(), day.getMonth(), day.getDate()+n); }
function monthDay(y, m, anchor){ const last = new Date(y, m+1, 0).getDate(); return new Date(y, m, Math.min(anchor, last)); }
/* next order cutoff after `from` */
function nextDeadline(sup, from=new Date()){
  const sched = sup.schedule || "weekly", cut = sup.cutoff;
  if (sched==="weekly"){
    const days = sup.days||[]; if (!days.length) return null;
    for (let i=0;i<8;i++){ const c = atCutoff(shiftDays(from,i), cut); if (days.includes(c.getDay()) && c > from) return c; }
    return null;
  }
  if (sched==="daily"){ const c = atCutoff(from, cut); return c > from ? c : atCutoff(shiftDays(from,1), cut); }
  if (!sup.start_date) return null;
  const start = parseDay(sup.start_date);
  if (sched==="once"){ const c = atCutoff(start, cut); return c > from ? c : null; }
  if (sched==="biweekly"){
    let d = start;
    if (atCutoff(d,cut) <= from){ const jumps = Math.max(0, Math.floor((from - atCutoff(d,cut)) / (14*86400e3)) - 1); d = shiftDays(d, 14*jumps); }
    for (let i=0; i<60 && atCutoff(d,cut) <= from; i++) d = shiftDays(d, 14);
    return atCutoff(d, cut);
  }
  if (sched==="monthly"){
    const anchor = start.getDate();
    let y = start.getFullYear(), m = start.getMonth();
    if (from > start){ y = from.getFullYear(); m = from.getMonth() - 1; }
    for (let i=0;i<40;i++){ const d = monthDay(y, m+i, anchor); const c = atCutoff(d, cut); if (d >= start && c > from) return c; }
    return null;
  }
  return null;
}
/* the most recent order cutoff at or before `from` */
function prevDeadline(sup, from=new Date()){
  const sched = sup.schedule || "weekly", cut = sup.cutoff;
  if (sched==="weekly"){
    const days = sup.days||[]; if (!days.length) return null;
    for (let i=0;i<8;i++){ const c = atCutoff(shiftDays(from,-i), cut); if (days.includes(c.getDay()) && c <= from) return c; }
    return null;
  }
  if (sched==="daily"){ const c = atCutoff(from, cut); return c <= from ? c : atCutoff(shiftDays(from,-1), cut); }
  if (!sup.start_date) return null;
  const start = parseDay(sup.start_date), first = atCutoff(start, cut);
  if (first > from) return null;
  if (sched==="once") return first;
  const n = nextDeadline(sup, from); if (!n) return null;
  const p = sched==="biweekly" ? atCutoff(shiftDays(n,-14), cut) : atCutoff(monthDay(n.getFullYear(), n.getMonth()-1, start.getDate()), cut);
  return p >= first ? p : null;
}
/* has the order for the next deadline been placed?
   An order placed right after a cutoff is usually a late order for the round that just closed, so it only
   counts toward the next deadline once it's placed in the second half of the round. When unsure, keep reminding. */
function orderedThisRound(sup){
  if (!sup.last_ordered_at) return false;
  const last = new Date(sup.last_ordered_at), setAt = sup.schedule_set_at ? new Date(sup.schedule_set_at) : null;
  if ((sup.schedule||"weekly")==="once") return setAt ? last >= setAt : true;
  const prev = prevDeadline(sup), next = nextDeadline(sup);
  if (prev && (!setAt || prev > setAt)){
    const mid = next ? new Date(prev.getTime() + (next - prev)/2) : prev;
    return last > mid;
  }
  return setAt ? last > setAt : false;
}
function supScheduleLabel(sup){
  const sched = sup.schedule || "weekly";
  const start = sup.start_date ? parseDay(sup.start_date) : null;
  if (sched==="weekly") return (sup.days||[]).length ? "Weekly · "+(sup.days||[]).slice().sort().map(i=>DAYS[i]).join(", ") : "Weekly";
  if (sched==="daily") return "Every day";
  if (sched==="biweekly") return "Every 2 weeks" + (start ? " · "+DAYS[start.getDay()] : "");
  if (sched==="monthly") return "Monthly" + (start ? " · "+ordinal(start.getDate()) : "");
  return "One time";
}
function supScheduleHint(n){
  const t = " by "+fmtClock(n.cutoff||"14:00");
  const start = n.start_date ? parseDay(n.start_date) : null;
  const first = start ? start.toLocaleDateString(undefined,{month:"short", day:"numeric"}) : "";
  if (n.schedule==="weekly"){ const ds = (n.days||[]).slice().sort().map(i=>DAYS[i]); return ds.length ? "Order every "+(ds.length>1 ? ds.slice(0,-1).join(", ")+" and "+ds[ds.length-1] : ds[0])+t+"." : "Pick the days you order."; }
  if (n.schedule==="daily") return "Order every day"+t+".";
  if (!start) return "Pick the first order date.";
  if (n.schedule==="biweekly") return "Order every other "+start.toLocaleDateString(undefined,{weekday:"long"})+t+", starting "+first+".";
  if (n.schedule==="monthly") return "Order on the "+ordinal(start.getDate())+" of every month"+t+", starting "+first+". Short months use their last day.";
  return "Order once, "+first+t+".";
}
function dueText(d){
  if (!d) return "No order days set";
  const now = new Date(), ms = d - now, t = d.toLocaleTimeString(undefined,{hour:"numeric",minute:"2-digit"});
  const tomorrow = new Date(now); tomorrow.setDate(now.getDate()+1);
  const day = d.toDateString()===now.toDateString() ? "Today" : d.toDateString()===tomorrow.toDateString() ? "Tomorrow" : d.toLocaleDateString(undefined,{weekday:"short"});
  const rel = ms < 3600e3 ? Math.max(1, Math.round(ms/60000))+" min" : ms < 48*3600e3 ? Math.round(ms/3600e3)+" h" : Math.round(ms/86400e3)+" days";
  return day+" "+t+" · in "+rel;
}
/* where an item is ordered from: its own supplier, or else its list's default supplier */
const catById = id => D().invcats.find(c=>c.id===id);
const supplierOf = it => it.supplier_id || (catById(it.cat_id)||{}).supplier_id || null;
const belowPar = supId => D().items.filter(it=>(supId===undefined || supplierOf(it)===supId) && (needOf(it)||0)>0);
const suppliersByDeadline = () => D().suppliers.map(s=>({s, d:nextDeadline(s), ordered:orderedThisRound(s)})).sort((a,b)=>Number(a.ordered)-Number(b.ordered)||(a.d?a.d.getTime():Infinity)-(b.d?b.d.getTime():Infinity)||a.s.name.localeCompare(b.s.name));

let toastTimer;
function toast(msg){
  const el = $("toast"); el.textContent = msg; el.hidden = false;
  el.classList.remove("show"); void el.offsetWidth; el.classList.add("show");
  clearTimeout(toastTimer); toastTimer = setTimeout(()=>el.hidden=true, 3400);
}
function askConfirm(key){ S.confirm = key; render(); setTimeout(()=>{ if (S.confirm===key){ S.confirm=null; render(); } }, 4000); }
function go(view){ S.view = view; S.confirm = null; render(); window.scrollTo(0,0); }
function openSheet(...kids){
  const sheet = $("sheet");
  sheet.replaceChildren(h("div",{class:"panel", role:"dialog", "aria-modal":"true"}, ...kids));
  sheet.hidden = false; sheet.onclick = e => { if (e.target===sheet) sheet.hidden = true; };
}
const closeSheet = () => { $("sheet").hidden = true; };
