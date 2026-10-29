/* JT Brewski's staff app — PWA front end. Talks to Supabase only through the api_* database functions. */
"use strict";

const CFG = window.BREWSKIS_CONFIG || {};
/* The app's version. Bump this, site/version.json and VERSION in site/sw.js together with every release. */
const APP_VERSION = 19;
const APP_DATE = "2026-10-29";
const ROLL_HOUR = 5;
const SESSION_KEY = "brewskis.session";
const CACHE_KEY = "brewskis.state";
const POLL_MS = 15000;
const SECTIONS = [["mgmt","Management","Mgr"],["foh","Front of house","FOH"],["boh","Back of house","BOH"]];
const secInfo = s => SECTIONS.find(x=>x[0]===s) || [s, s, s];
const DAYS = ["Sun","Mon","Tue","Wed","Thu","Fri","Sat"];
const STARTERS = {
  "manager":["Walk every station before open","Check that each shift list is finished","Review inventory counts and place orders before the deadlines","Count the safe and verify the deposit","Check the bathrooms and the floor","Lock up and set the alarm"],
  "opening-bartender":["Count the drawer and log the starting bank","Check kegs and CO2, swap any empties","Fill the ice wells","Cut fruit and garnishes","Stock beer coolers, oldest to the front","Set out mats, napkins and straws","Wipe down bar top and stools","Turn on TVs and music","Count bar supplies on the Inventory tab"],
  "closing-bartender":["Close out all open tabs","Count the drawer and make the deposit drop","Restock coolers for the morning","Wrap and store garnishes","Empty and clean the ice wells","Soak mats and pour spouts","Clean the tap nozzles","Wipe down bar top, rails and stools","Take out trash and recycling","Count paper products on the Inventory tab"],
  "barback":["Keep ice stocked through the rush","Change kegs as they kick","Restock glassware from dish","Bring liquor up from storage","Run empties and recycling","Keep the floor behind the bar dry and clear"],
  "opening-cook":["Log walk-in and reach-in temps","Turn on fryers, flat top and ovens","Work through today's prep list","Label and date all new prep","Rotate proteins first in, first out","Stock the line","Check the fryer oil"],
  "closing-cook":["Wrap, label and date all prep","Scrape and clean the flat top and grill","Filter or change the fryer oil","Clean and sanitize the line","Sweep and mop the kitchen","Log 86'd and low items for the morning","Turn off all equipment and check the gas"],
  "dishwasher":["Fill and test the sanitizer","Run and put away all dishes","Clean the dish machine and pull the screens","Take out kitchen trash","Sweep and mop the dish area","Restock clean racks for bar and line"]
};
const INV_STARTERS = {
  "bar-supplies":[["Limes","cases"],["Lemons","cases"],["Oranges","cases"],["Maraschino cherries","jars"],["Olives","jars"],["Sour mix","bottles"],["Simple syrup","bottles"],["Grenadine","bottles"],["Bloody Mary mix","bottles"],["Bar towels","bundles"],["CO2 tanks","tanks"],["Sanitizer","gallons"]],
  "paper-products":[["Beverage napkins","cases"],["Dinner napkins","cases"],["Straws","boxes"],["Stir sticks","boxes"],["Coasters","boxes"],["Paper towels","cases"],["Toilet paper","cases"],["To-go containers","cases"],["To-go bags","packs"],["Plastic cutlery kits","cases"],["Receipt paper","boxes"],["Trash bags","cases"]]
};

const S = {
  session:null, data:null, dataAt:null, offline:!navigator.onLine, booting:true,
  view:"overview", roleId:null, filter:"all", invFilter:"all", invEdit:false, confirm:null,
  draft:{text:"", assignee:"", repeat:"daily", due_date:"", due_time:""}, editTask:null, editDraft:null, newPerson:"", newRole:"", newRoleSection:"foh",
  newItem:{}, newCat:"", newSup:{name:"", days:[], cutoff:"14:00", notes:"", schedule:"weekly", start_date:""},
  countDraft:{}, countTimers:{}, actQuery:"", actRange:"all", actLimit:10,
  pin:"", loginErr:"", loginBusy:false, lockUntil:0, pinEdit:null, pinDraft:"", pinErr:"", pinBusy:false,
  invQuery:"", invSup:null, open:loadOpen(), fx:{},
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
    not_found:"That was already removed."
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
async function refresh(){
  if (!S.session) return;
  try {
    const d = await call("api_state");
    S.data = d; S.dataAt = new Date().toISOString();
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
async function applyUpdate(){
  S.updating = true; render();
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
function setOffline(v){ if (S.offline!==v){ S.offline = v; renderOffline(); } }

/* ---------- session ---------- */
function loadSession(){ try { const v = localStorage.getItem(SESSION_KEY); return v ? JSON.parse(v) : null; } catch(e){ return null; } }
function storeSession(s){ try { s ? localStorage.setItem(SESSION_KEY, JSON.stringify(s)) : localStorage.removeItem(SESSION_KEY); } catch(e){} }
function logOut(msg){
  const tok = S.session && S.session.token;
  S.session = null; S.data = null; storeSession(null);
  try { localStorage.removeItem(CACHE_KEY); } catch(e){}
  if (tok) rpc("api_logout", {p_token:tok}).catch(()=>{});
  S.view = "overview"; S.invEdit = false; S.pin = "";
  document.getElementById("sheet").hidden = true;
  if (msg) toast(msg);
  render();
}

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
function shiftDayLabel(){ const [y,m,d] = shiftDay().split("-").map(Number); return "Shift day: " + new Date(y,m-1,d).toLocaleDateString(undefined,{weekday:"short",month:"short",day:"numeric"}); }
function shiftStartISO(){ const [y,m,d] = shiftDay().split("-").map(Number); return new Date(y, m-1, d, ROLL_HOUR).toISOString(); }
function when(iso){
  if (!iso) return ""; const d = new Date(iso); const now = new Date();
  const t = d.toLocaleTimeString(undefined,{hour:"numeric",minute:"2-digit"});
  return d.toDateString()===now.toDateString() ? t : d.toLocaleDateString(undefined,{month:"short",day:"numeric"})+", "+t;
}
function initials(n){ return (n||"?").trim().split(/\s+/).map(s=>s[0]).slice(0,2).join("").toUpperCase() || "?"; }
const D = () => S.data || {roles:[], staff:[], tasks:[], invcats:[], items:[], counts:[], suppliers:[], log:[], me:null};
const me = () => D().me;
const isAdmin = () => !!(me() && me().manager);
const canWrite = () => !!me() && !S.offline;
const roleById = id => D().roles.find(r=>r.id===id);
const roleName = id => (roleById(id)||{}).name || "";
const staffById = id => D().staff.find(s=>s.id===id);
const isManagerStaff = s => !!s && (s.roles||[]).some(id=>(roleById(id)||{}).section==="mgmt");
/* ---------- task schedules ---------- */
const REPEATS = [["daily","Every shift"],["weekly","Weekly"],["biweekly","Every 2 weeks"],["monthly","Monthly"],["once","Just once"]];
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

/* ---------- actions ---------- */
async function toggleTask(t){
  if (!canWrite()) return toast(errMsg({code:"offline"}));
  const before = {done:t.done, done_day:t.done_day, done_until:t.done_until, done_by:t.done_by, done_by_name:t.done_by_name, done_at:t.done_at};
  if (isDone(t)) Object.assign(t, {done:false, done_day:null, done_until:null, done_by:null, done_by_name:null, done_at:null});
  else Object.assign(t, {done:true, done_day:shiftDay(), done_until:RECURRING.has(t.repeat) ? new Date(Date.now()+3600e3).toISOString() : null,
                         done_by:me().id, done_by_name:me().name, done_at:new Date().toISOString()});
  S.fx.task = t.id;
  if (!isDone(t)) play("undo");
  else { const rp = progressOf(roleTasks(t.role_id).filter(countsToday)); play(rp.total && rp.done===rp.total ? "cheers" : "clink"); }
  render();
  if (!(await act("api_toggle_task", {p_id:t.id}))){ Object.assign(t, before); render(); }
}
function setCount(it, n, quiet){
  if (!canWrite()) return toast(errMsg({code:"offline"}));
  if (!Number.isFinite(n) || n<0) n = 0;
  if (!quiet){ const before = onHandOf(it); play(before!=null && n < before ? "tickDown" : "tickUp"); }
  S.countDraft[it.id] = n;
  if (!quiet){ S.fx.count = it.id; render(); }
  clearTimeout(S.countTimers[it.id]);
  S.countTimers[it.id] = setTimeout(async ()=>{
    const v = S.countDraft[it.id];
    await act("api_set_count", {p_item_id:it.id, p_on_hand:v});
    if (S.countDraft[it.id]===v) delete S.countDraft[it.id];
    render();
  }, 700);
}
function orderText(name, items){ return name+" order · JT Brewskis\n" + items.map(it=>"- "+it.name+": "+fmtN(needOf(it))+(it.unit?" "+it.unit:"")).join("\n"); }
async function sendOrder(name, items){
  const text = orderText(name, items);
  if (navigator.share){ try { await navigator.share({title:name+" order", text}); return; } catch(e){ if (e && e.name==="AbortError") return; } }
  try { await navigator.clipboard.writeText(text); toast("Order copied. Paste it into a text or email."); }
  catch(e){
    const ta = h("textarea",{id:"orderText", rows:Math.min(14, items.length+2), readonly:true, value:text});
    openSheet(h("h2",{text:"Copy this order"}), h("p",{class:"hint", text:"Select the text below and copy it."}), ta, h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Close"));
    ta.focus(); ta.select();
  }
}
function randomNumber(){ return String(1000 + (crypto.getRandomValues(new Uint32Array(1))[0] % 9000)); }
async function saveNumber(s){
  const pin = S.pinDraft.trim();
  if (!/^\d{4,6}$/.test(pin)){ S.pinErr = "Use 4 to 6 digits."; return render(); }
  S.pinBusy = true; S.pinErr = ""; render();
  try { await call("api_set_pin", {p_id:s.id, p_pin:pin}); S.pinEdit = null; S.pinDraft = ""; showNumber(s.name, pin); await refresh(); }
  catch(e){ if (e.code==="not_logged_in") return logOut("You've been logged out. Enter your number again."); S.pinErr = errMsg(e); }
  finally { S.pinBusy = false; render(); }
}
function showNumber(name, pin){
  openSheet(h("h2",{text:name+"'s login number"}), h("div",{class:"bignum", text:pin}),
    h("p",{class:"hint", text:"Tell "+name+" now. The number isn't shown again. If it's forgotten, assign a new one."}),
    h("button",{type:"button", class:"btn", onclick:closeSheet},"Done"));
}

/* ---------- login ---------- */
function pressKey(k){
  if (S.loginBusy) return;
  if (Date.now() < S.lockUntil) return render();
  S.loginErr = "";
  if (k==="del") S.pin = S.pin.slice(0,-1);
  else if (k==="clear") S.pin = "";
  else if (k==="go") return submitPin();
  else if (S.pin.length < 6){ S.pin += k; S.fx.dot = S.pin.length; }
  render();
}
async function submitPin(){
  if (S.pin.length < 4){ S.loginErr = "Numbers are 4 to 6 digits."; return render(); }
  S.loginBusy = true; render();
  try {
    const r = await rpc("api_login", {p_pin:S.pin});
    if (r && r.token){
      play("ok");
      S.session = {token:r.token, staffId:r.staff_id, at:Date.now()}; storeSession(S.session);
      S.pin = ""; S.view = "overview"; S.booting = true;
      await refresh(); window.scrollTo(0,0); return;
    }
    S.pin = "";
    if (r && r.error==="too_many_attempts"){ S.lockUntil = Date.now()+60000; S.loginErr = "Too many wrong numbers. Wait a minute and try again."; setTimeout(()=>{ S.loginErr=""; render(); }, 60000); }
    else { S.loginErr = "That number doesn't match anyone. Try again or ask a manager."; S.fx.shake = true; play("nope"); }
  } catch(e){ S.loginErr = e.code==="offline" ? "You're offline. Connect to log in." : "Couldn't reach the server. Try again."; }
  finally { S.loginBusy = false; render(); }
}
function viewLogin(){
  const locked = Date.now() < S.lockUntil;
  const keys = ["1","2","3","4","5","6","7","8","9","clear","0","del"], label = {clear:"Clear", del:"⌫"};
  return [h("section",{class:"login", "aria-label":"Log in"},
    h("div",{class:"logo", role:"img", "aria-label":"JT Brewski's Pub logo"}),
    h("h2",{text:"Enter your number"}),
    h("p",{class:"hint", text:"Your manager gives you a 4 to 6 digit login number."}),
    h("div",{class:"pindots"+(S.fx.shake?" shake":""), "aria-live":"polite", "aria-label":S.pin.length+" digits entered"}, Array.from({length:Math.max(4, S.pin.length)}, (_,i)=>h("span",{class:(i<S.pin.length?"on":"")+(S.fx.dot===i+1?" pop":"")}))),
    h("p",{class:"loginerr", role:"alert", text:S.loginBusy ? "Checking…" : S.loginErr}),
    h("div",{class:"keypad"}, keys.map(k=>h("button",{type:"button", class:"key"+(label[k]?" fn":""), disabled:locked||S.loginBusy, "aria-label":k==="del"?"Delete":k==="clear"?"Clear":k, onclick:()=>pressKey(k)}, label[k]||k))),
    h("button",{type:"button", class:"btn", style:"width:100%", disabled:locked||S.loginBusy||S.pin.length<4, "data-own-sound":"", onclick:()=>pressKey("go")},"Log in"))];
}
function viewNotConfigured(){
  return [h("div",{class:"empty"}, h("h2",{text:"Almost ready"}),
    h("p",{text:"This copy of the app isn't connected to a database yet. Put your Supabase project URL and anon key in config.js, then reload."}))];
}

/* ---------- account + install ---------- */
const isStandalone = () => window.matchMedia("(display-mode: standalone)").matches || navigator.standalone === true;
const isIOS = () => /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform==="MacIntel" && navigator.maxTouchPoints>1);
function openAccount(){
  const m = me(); if (!m) return;
  openSheet(
    h("h2",{text:"Logged in as "+m.name}),
    h("p",{class:"hint", text:((m.roles||[]).map(roleName).filter(Boolean).join(", ") || "No roles yet") + ". This device logs out by itself 16 hours after you log in."}),
    h("label",{class:"soundrow", for:"soundToggle"},
      h("span",{}, h("b",{text:"Sounds"}), h("span",{class:"hint", text:"A soft tap on every button, a clink when you check off a task, and ticks when you count."+(navigator.vibrate ? " Includes a short vibration." : "")})),
      h("input",{type:"checkbox", id:"soundToggle", class:"switch", role:"switch", checked:soundOn, onchange:e=>setSound(e.target.checked)})),
    versionLine(),
    updateReady() ? h("button",{type:"button", class:"btn", disabled:S.updating, onclick:()=>{ closeSheet(); applyUpdate(); }}, S.updating ? "Updating…" : "Update now") : null,
    !isStandalone() ? installHelp() : null,
    m.manager ? h("button",{type:"button", class:"btn ghost", onclick:()=>{ closeSheet(); openNotify(); }},"Notification settings") : null,
    h("button",{type:"button", class:"btn", onclick:()=>logOut()},"Log out"),
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Cancel"));
}
/* ---------- manager notifications ---------- */
const pushSupported = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
function b64uToBytes(str){ const pad = "=".repeat((4 - str.length % 4) % 4); const raw = atob((str + pad).replace(/-/g,"+").replace(/_/g,"/")); return Uint8Array.from(raw, c=>c.charCodeAt(0)); }
const functionsUrl = () => CFG.supabaseUrl.replace(/\/$/,"") + "/functions/v1/notify";
function openNotify(){ S.view = "notify"; S.push.err = ""; render(); window.scrollTo(0,0); loadPush(); }
async function loadPush(){
  if (!pushSupported() || Notification.permission==="denied"){ S.push.loaded = true; return render(); }
  try {
    const reg = await navigator.serviceWorker.ready;
    const sub = await reg.pushManager.getSubscription();
    S.push.sub = sub;
    S.push.prefs = sub ? await call("api_push_get",{p_endpoint:sub.endpoint}) : null;
  } catch(e){ if (e.code==="not_logged_in") return logOut("You've been logged out. Enter your number again."); S.push.err = errMsg(e); }
  S.push.loaded = true; render();
}
async function savePush(prefs){
  const j = S.push.sub.toJSON();
  S.push.prefs = await call("api_push_save",{p_endpoint:j.endpoint, p_p256dh:j.keys.p256dh, p_auth:j.keys.auth, p_prefs:prefs});
}
async function enablePush(){
  S.push.busy = true; S.push.err = ""; render();
  try {
    const perm = await Notification.requestPermission();
    if (perm !== "granted"){ S.push.err = "Notifications weren't allowed on this phone."; return; }
    const reg = await navigator.serviceWorker.ready;
    let sub = await reg.pushManager.getSubscription();
    if (!sub) sub = await reg.pushManager.subscribe({userVisibleOnly:true, applicationServerKey:b64uToBytes(CFG.vapidPublicKey)});
    S.push.sub = sub;
    await savePush(S.push.prefs || {});
    toast("Notifications are on for this phone.");
  } catch(e){ S.push.err = e && e.code ? errMsg(e) : "This phone couldn't turn on notifications. Try again in a moment."; }
  finally { S.push.busy = false; render(); }
}
async function updatePush(patch){
  const before = {...S.push.prefs};
  Object.assign(S.push.prefs, patch); render();
  try { await savePush(S.push.prefs); } catch(e){ S.push.prefs = before; toast(errMsg(e)); }
  render();
}
async function testPush(){
  S.push.busy = true; render();
  try {
    const r = await fetch(functionsUrl(), {method:"POST", headers:{"Content-Type":"application/json", "apikey":CFG.supabaseAnonKey},
      body:JSON.stringify({test:true, token:S.session.token, endpoint:S.push.sub.endpoint})});
    const d = await r.json().catch(()=>({}));
    toast(d.sent ? "Test sent. It should show up in a few seconds." : d.removed ? "This phone stopped accepting notifications. Turn them off and on again." : "The test didn't send. Try again in a minute.");
  } catch(e){ toast("Couldn't reach the notification service. Check your connection."); }
  finally { S.push.busy = false; render(); }
}
async function disablePush(){
  S.push.busy = true; render();
  try { await call("api_push_remove",{p_endpoint:S.push.sub.endpoint}); await S.push.sub.unsubscribe(); S.push.sub = null; S.push.prefs = null; toast("Notifications are off for this phone."); }
  catch(e){ toast(errMsg(e)); }
  finally { S.push.busy = false; render(); }
}
function prefRow(key, title, desc, extra){
  const on = !!S.push.prefs[key];
  return h("div",{class:"prefrow"},
    h("label",{class:"preflabel", for:"pf-"+key},
      h("input",{type:"checkbox", id:"pf-"+key, checked:on, disabled:S.push.busy, onchange:e=>updatePush({[key]:e.target.checked})}),
      h("span",{}, h("b",{text:title}), h("span",{class:"hint", text:desc}))),
    on && extra ? h("div",{class:"prefextra"}, extra) : null);
}
function viewNotify(){
  if (!isAdmin()){ S.view = "overview"; return viewOverview(); }
  const out = [h("div",{class:"rolehead"},
    h("button",{type:"button", class:"back", onclick:()=>go("overview")},"← Back"),
    h("h2",{text:"Notifications", style:"font-size:32px"}),
    h("p",{class:"hint", text:"These settings are for this phone only. Each manager turns notifications on on their own phone."}))];
  if (!pushSupported()){
    out.push(isIOS() && !isStandalone()
      ? h("div",{class:"card"}, h("h3",{text:"Add the app to your home screen first"}),
          h("p",{class:"hint", text:"iPhones only allow notifications from apps opened from the home screen (iOS 16.4 or newer)."}),
          h("ol",{class:"steps"}, h("li",{text:"Open this page in Safari."}), h("li",{text:"Tap Share, then Add to Home Screen."}), h("li",{text:"Open Brewskis from your home screen and come back here."})))
      : emptyCard("Notifications aren't available here", isIOS() ? "Update your iPhone to iOS 16.4 or newer to get notifications." : "This browser can't receive notifications. On Android, use Chrome."));
    return out;
  }
  if (Notification.permission==="denied"){
    out.push(emptyCard("Notifications are blocked", isIOS() ? "Open your iPhone's Settings, tap Notifications, then Brewskis, and turn on Allow Notifications. Then come back here." : "In Chrome, tap the icon to the left of the address (or Settings → Site settings → Notifications) and allow notifications for this site. Then come back here."));
    return out;
  }
  if (!S.push.loaded){ out.push(h("p",{class:"hint", text:"Checking this phone…"})); return out; }
  if (S.push.err) out.push(h("p",{class:"loginerr", role:"alert", text:S.push.err}));
  if (!S.push.sub || !S.push.prefs){
    out.push(h("div",{class:"card"},
      h("h3",{text:"Get alerts on this phone"}),
      h("ul",{class:"steps"},
        h("li",{text:"Order deadlines coming up that haven't been ordered"}),
        h("li",{text:"Tasks that go overdue, and items counted at zero"}),
        h("li",{text:"A recap of each shift day's checklists"})),
      h("button",{type:"button", class:"btn", disabled:S.push.busy, onclick:enablePush}, S.push.busy ? "Turning on…" : "Turn on notifications")));
    return out;
  }
  const p = S.push.prefs;
  const timeInput = (id, key) => h("input",{type:"time", id, value:p[key], disabled:S.push.busy, onchange:e=>{ if (e.target.value) updatePush({[key]:e.target.value}); }});
  out.push(h("div",{class:"card prefs"},
    prefRow("orders", "Order deadlines", "Before a supplier's cutoff, if that order hasn't been marked placed.",
      h("label",{class:"lbl", for:"pfLead"}, "Remind me",
        h("select",{id:"pfLead", disabled:S.push.busy, onchange:e=>updatePush({lead_hours:Number(e.target.value)})},
          [[1,"1 hour before"],[2,"2 hours before"],[4,"4 hours before"],[24,"1 day before"]].map(([v,l])=>h("option",{value:v, selected:Number(p.lead_hours)===v}, l))))),
    prefRow("overdue", "Overdue tasks", "When a task passes its due date or due time without being checked off. One alert per task."),
    prefRow("out", "Out of stock", "When someone counts an item at 0."),
    prefRow("summary", "Nightly recap", "How many checklist tasks got done in the shift day that just ended, and what was missed.",
      h("label",{class:"lbl", for:"pfRecap"}, "Send at", timeInput("pfRecap","summary_time"))),
    prefRow("quiet", "Quiet hours", "Alerts wait until quiet hours end. The recap still arrives at the time you picked.",
      h("div",{class:"inline"}, h("label",{class:"lbl", for:"pfQs"}, "From", timeInput("pfQs","quiet_start")), h("label",{class:"lbl", for:"pfQe"}, "To", timeInput("pfQe","quiet_end"))))));
  out.push(h("div",{class:"inline"},
    h("button",{type:"button", class:"btn", disabled:S.push.busy, onclick:testPush},"Send a test"),
    h("button",{type:"button", class:"btn ghost", disabled:S.push.busy, onclick:disablePush},"Turn off on this phone")));
  out.push(h("p",{class:"hint", text:"Alerts are checked every 15 minutes, so they can arrive up to 15 minutes after something happens."}));
  return out;
}
function installHelp(){
  if (S.installEvent) return h("button",{type:"button", class:"btn ghost", onclick:install},"Install the app on this device");
  if (isIOS()) return h("div",{class:"card"}, h("h3",{text:"Add it to your home screen"}),
    h("ol",{class:"steps"}, h("li",{text:"Open this page in Safari."}), h("li",{text:"Tap the Share button."}), h("li",{text:"Tap Add to Home Screen, then Add."})));
  return null;
}
async function install(){ const ev = S.installEvent; if (!ev) return; S.installEvent = null; $("installBtn").hidden = true; closeSheet(); ev.prompt(); try { await ev.userChoice; } catch(e){} }

/* ---------- shared bits ---------- */
function progressOf(tasks){ const done = tasks.filter(isDone).length; return {done, total:tasks.length, pct: tasks.length ? Math.round(done/tasks.length*100) : 0}; }
/* today's progress as a stein from the logo: beer rises with the share of tasks done */
/* ---------- sound effects ----------
   Made on the fly with Web Audio, no sound files. Each phone can turn them off (tap your name).
   On iPhone they follow the ring/silent switch; on Android, media volume. Android also gets a short vibration. */
let soundOn = (()=>{ try { return localStorage.getItem("brewskis.sound") !== "off"; } catch(e){ return true; } })();
let actx = null;
function audio(){
  if (!actx){
    const AC = window.AudioContext || window.webkitAudioContext; if (!AC) return null;
    try { if (navigator.audioSession) navigator.audioSession.type = "ambient"; } catch(e){}   // respect silent mode, don't stop other audio
    actx = new AC();
  }
  if (actx.state==="suspended") actx.resume().catch(()=>{});
  return actx;
}
function tone(ctx, dest, t, o){
  const osc = ctx.createOscillator(), g = ctx.createGain(), dur = o.dur || 0.2;
  osc.type = o.type || "sine";
  osc.frequency.setValueAtTime(o.freq, t);
  if (o.to) osc.frequency.exponentialRampToValueAtTime(o.to, t + dur);
  g.gain.setValueAtTime(0.0001, t);
  g.gain.exponentialRampToValueAtTime(o.gain || 0.2, t + (o.attack || 0.004));
  g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
  osc.connect(g); g.connect(dest); osc.start(t); osc.stop(t + dur + 0.03);
}
const SOUNDS = {
  /* checking off a task: two glasses touching */
  clink(ctx, d, t){
    [[2093,.20,.55],[3135,.10,.38],[4186,.05,.22]].forEach(([f,g,dur])=>tone(ctx,d,t,{freq:f,gain:g,dur}));
    [[2489,.14,.45],[3729,.07,.30]].forEach(([f,g,dur])=>tone(ctx,d,t+.065,{freq:f,gain:g,dur}));
  },
  /* last task on a role's list for today: a rising chime, then the clink */
  cheers(ctx, d, t){
    [784,988,1319].forEach((f,i)=>{ tone(ctx,d,t+i*.09,{freq:f,type:"triangle",gain:.18,dur:.38}); tone(ctx,d,t+i*.09,{freq:f*2,gain:.05,dur:.25}); });
    SOUNDS.clink(ctx, d, t+.3);
  },
  /* intro: a light woosh that rises with the pour (noise swept up through a filter) */
  woosh(ctx, d, t, len){
    len = len || .9;
    const n = Math.ceil(ctx.sampleRate*len), buf = ctx.createBuffer(1, n, ctx.sampleRate), ch = buf.getChannelData(0);
    for (let i=0;i<n;i++) ch[i] = Math.random()*2 - 1;
    const src = ctx.createBufferSource(); src.buffer = buf;
    const bp = ctx.createBiquadFilter(); bp.type = "bandpass"; bp.Q.value = .8;
    bp.frequency.setValueAtTime(260, t); bp.frequency.exponentialRampToValueAtTime(2400, t+len*.72); bp.frequency.exponentialRampToValueAtTime(1500, t+len);
    const g = ctx.createGain();
    g.gain.setValueAtTime(.0001, t); g.gain.exponentialRampToValueAtTime(.28, t+len*.6); g.gain.exponentialRampToValueAtTime(.0001, t+len);
    src.connect(bp); bp.connect(g); g.connect(d); src.start(t); src.stop(t+len+.02);
  },
  wooshQuick(ctx, d, t){ SOUNDS.woosh(ctx, d, t, .45); },
  /* any other button: a short, soft wooden tap */
  tap(ctx, d, t){ tone(ctx,d,t,{freq:760,to:540,type:"sine",gain:.11,dur:.032,attack:.002}); tone(ctx,d,t,{freq:2300,type:"sine",gain:.025,dur:.012,attack:.001}); },
  /* unchecking: a soft falling tock */
  undo(ctx, d, t){ tone(ctx,d,t,{freq:520,to:330,type:"triangle",gain:.16,dur:.14}); },
  /* counting: tiny ticks, higher for +, lower for − */
  tickUp(ctx, d, t){ tone(ctx,d,t,{freq:1500,type:"triangle",gain:.12,dur:.045}); },
  tickDown(ctx, d, t){ tone(ctx,d,t,{freq:1000,type:"triangle",gain:.12,dur:.045}); },
  /* logged in, order placed: two notes up */
  ok(ctx, d, t){ tone(ctx,d,t,{freq:660,type:"triangle",gain:.17,dur:.12}); tone(ctx,d,t+.1,{freq:990,type:"triangle",gain:.17,dur:.24}); },
  /* wrong number, couldn't save: two low notes down */
  nope(ctx, d, t){ tone(ctx,d,t,{freq:233,type:"square",gain:.05,dur:.11}); tone(ctx,d,t+.14,{freq:185,type:"square",gain:.05,dur:.16}); }
};
const BUZZ = {clink:12, cheers:[15,60,30], ok:10, nope:[40,60,40]};
function play(name){
  if (!soundOn) return;
  try { const ctx = audio(); if (ctx) SOUNDS[name](ctx, ctx.destination, ctx.currentTime + .01); } catch(e){}
  try { if (BUZZ[name] && navigator.vibrate) navigator.vibrate(BUZZ[name]); } catch(e){}
}
/* every button tap gets the soft tap, unless that button plays its own sound */
document.addEventListener("click", e=>{
  const el = e.target.closest && e.target.closest("button, select, [role=button], a[href]");
  if (!el || el.disabled || el.hasAttribute("data-own-sound")) return;
  play("tap");
}, true);
function setSound(on){
  soundOn = on;
  try { localStorage.setItem("brewskis.sound", on ? "on" : "off"); } catch(e){}
  if (on) play("clink");
}

/* ---------- motion ----------
   Bars and the stein remember the last value they showed and slide to the new one, so checking off a task
   visibly fills them. The stein pours from empty the first time it's shown after the app opens. */
const lastShown = new Map();
function growFrom(key, pct, firstFrom){
  const to = Math.max(0, Math.min(100, pct));
  const from = lastShown.has(key) ? lastShown.get(key) : firstFrom;
  lastShown.set(key, to);
  return {from: from==null ? to : from, to};
}
function stein(pct){
  const g = growFrom("stein", pct, 0);
  return h("div",{class:"stein", "aria-hidden":"true"},
    h("div",{class:"stein-glass"},
      h("div",{class:"stein-beer"+(pct>0?" has-foam":""), style:"height:"+g.from+"%", "data-grow-h":g.to}),
      h("div",{class:"stein-hoops"})));
}
function bar(pct, key){
  const g = key ? growFrom(key, pct) : {from:pct, to:pct};
  return h("div",{class:"bar", role:"progressbar", "aria-valuenow":pct, "aria-valuemin":0, "aria-valuemax":100},
    h("i",{style:"width:"+g.from+"%", "data-grow-w":g.to}));
}
/* after each render: slide bars to their new values, and fade in a newly opened screen */
let lastScreen = null;
function afterRender(){
  const els = document.querySelectorAll("[data-grow-w],[data-grow-h]");
  if (els.length){
    els[0].getBoundingClientRect();   // lock in the starting size so the change animates
    requestAnimationFrame(()=>els.forEach(el=>{
      if (el.dataset.growW!=null) el.style.width = el.dataset.growW+"%";
      if (el.dataset.growH!=null) el.style.height = el.dataset.growH+"%";
    }));
  }
  const screen = !S.session ? "login" : S.view + (S.view==="role" ? ":"+S.roleId : "");
  if (screen !== lastScreen){
    const main = $("view");
    if (lastScreen !== null){ main.classList.remove("enter"); void main.offsetWidth; main.classList.add("enter"); }
    lastScreen = screen;
  }
  S.fx = {};   // one-shot effects only play on the render that triggered them
}
function emptyCard(title, body, ...actions){ actions = actions.filter(Boolean); return h("div",{class:"empty"}, h("h2",{text:title}), h("p",{text:body}), actions.length ? h("div",{class:"inline"}, actions) : null); }
function svgCheck(){ const s = document.createElementNS("http://www.w3.org/2000/svg","svg"); s.setAttribute("viewBox","0 0 24 24"); s.innerHTML = '<path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" style="color:var(--card)"/>'; return s; }
const doneName = t => t.done_by_name || staffName(t.done_by);
const addedName = t => t.added_by_name || (t.added_by ? staffName(t.added_by) : "Someone");

/* ---------- Shifts ---------- */
/* which sides of the pub this person sees: managers see everything; everyone else sees the
   side(s) their roles are on (front of house, back of house, or both). Management lists are managers only. */
function visibleSections(){
  const m = me(); if (!m) return new Set();
  if (m.manager) return new Set(["mgmt","foh","boh"]);
  const secs = new Set((m.roles||[]).map(id=>(roleById(id)||{}).section).filter(Boolean));
  secs.delete("mgmt");
  return secs;
}
const canSeeRole = r => !!r && visibleSections().has(r.section);

function viewOverview(){
  const out = [], d = D(), admin = isAdmin();
  if (!d.roles.length) return [emptyCard("No roles set up yet", admin ? "Add roles on the Team tab. Each role gets its own checklist." : "A manager needs to set up the roles first.")];
  const secs = visibleSections();
  if (!secs.size) return [emptyCard("No role yet", "A manager needs to give you a role before your checklists show up here."), activitySection()];
  const all = d.tasks.filter(t=>canSeeRole(roleById(t.role_id)) && countsToday(t));
  const p = progressOf(all);
  const myRoles = new Set(me().roles||[]);
  const scope = admin || (secs.has("foh") && secs.has("boh")) ? "tasks done today, across every shift" : secs.has("foh") ? "front of house tasks done today" : "back of house tasks done today";
  out.push(h("section",{class:"summary", "aria-label":"Today's progress: "+p.done+" of "+p.total+" tasks done"},
    stein(p.pct),
    h("div",{class:"sumtext"},
      h("div",{class:"big"}, String(p.done), h("small",{text:" of "+p.total})),
      h("div",{class:"sumlabel", text: p.total ? (p.done===p.total ? "Everything due today is done" : scope) : "Nothing due today. Open a role to add tasks."}),
      p.total && p.done < p.total ? h("div",{class:"sumleft", text:(p.total-p.done)+" to go"}) : null)));
  if (admin && d.suppliers.length){
    const next = suppliersByDeadline().find(x=>x.d && !x.ordered);
    if (next){
      const n = belowPar(next.s.id).length, soon = next.d - new Date() < 24*3600e3;
      out.push(h("button",{type:"button", class:"strip"+(soon?" urgent":""), onclick:()=>go("inventory")},
        h("span",{class:"t"}, h("span",{class:"eyebrow", text:"Next order deadline"}), h("span",{style:"font-weight:700", text:next.s.name}), h("span",{class:"due"+(soon?" soon":""), text:dueText(next.d)})),
        h("span",{class:"tag "+(n?"warn":"ok"), text: n ? n+" to order" : "Nothing low"})));
    }
  }
  for (const [sec, label, short] of SECTIONS){
    if (!secs.has(sec)) continue;
    const roles = sortedRoles(sec); if (!roles.length) continue;
    out.push(h("section",{},
      h("div",{class:"sec-head"}, h("h2",{class:"sec-"+sec, text:label}), h("span",{class:"tag "+sec, text:short})),
      h("div",{class:"rows"}, roles.map(r=>{
        const rp = progressOf(roleTasks(r.id).filter(countsToday)); const people = roleStaff(r.id).map(s=>s.name);
        const over = roleTasks(r.id).filter(isOverdue).length;
        return h("button",{type:"button", class:"role"+(myRoles.has(r.id)?" mine":""), onclick:()=>{ S.roleId=r.id; S.filter="all"; go("role"); }},
          h("span",{class:"name", text:r.name + (myRoles.has(r.id) ? " · You" : "")}),
          h("span",{class:"count"}, h("span",{text: rp.total ? rp.done+"/"+rp.total : "No tasks"}), rp.total ? bar(rp.pct, "role:"+r.id) : null),
          h("span",{class:"people", text: (over ? over+" overdue · " : "") + (people.length ? people.join(", ") : "No one assigned")}));
      }))));
  }
  out.push(activitySection());
  return out;
}

function activitySection(){
  const admin = isAdmin();
  const VERB = {done:" checked off “%”", undone:" unchecked “%”", added:" added “%”", removed:" removed “%”", edited:" edited “%”", count:" counted %", ordered:" placed the % order", tapped:" put % on tap", kicked:" marked % kicked"};
  /* staff only see activity from their side of the pub, plus inventory counts */
  const placeOk = admin ? ()=>true : (()=>{ const ok = new Set(D().roles.filter(canSeeRole).map(r=>r.name)); ok.add("Inventory"); return place=>ok.has(place); })();
  const ev = D().log.filter(l=>placeOk(l.place||"")).map(l=>({at:l.at, who:l.who_name || staffName(l.who), what:(VERB[l.kind]||" updated %").replace("%", l.text||""), where:l.place||""}));
  let shown = ev;
  const q = admin ? S.actQuery.trim().toLowerCase() : "";
  if (admin && S.actRange!=="all"){ const cut = S.actRange==="today" ? shiftStartISO() : new Date(Date.now()-7*86400e3).toISOString(); shown = shown.filter(e=>new Date(e.at).toISOString()>=cut); }
  if (q){ const words = q.split(/\s+/); shown = shown.filter(e=>{ const hay = (e.who+e.what+" "+e.where+" "+when(e.at)).toLowerCase(); return words.every(w=>hay.includes(w)); }); }
  const limit = q ? 100 : admin ? S.actLimit : 10;
  const sec = h("section",{class:"stack"}, h("div",{class:"sec-head", style:"margin:0"}, h("h2",{text:"Latest activity"}), q ? h("span",{class:"hint", text:shown.length+(shown.length===1?" match":" matches")}) : null));
  if (admin){
    sec.append(h("input",{type:"search", id:"actSearch", placeholder:"Search a name, task or item", "aria-label":"Search activity", autocomplete:"off", value:S.actQuery, oninput:e=>{ S.actQuery = e.target.value; render(); }}));
    sec.append(h("div",{class:"chips", role:"group", "aria-label":"Time range"},
      [["today","This shift day"],["week","Last 7 days"],["all","Everything"]].map(([id,label])=>
        h("button",{type:"button", class:"chip", "aria-pressed":S.actRange===id?"true":"false", onclick:()=>{ S.actRange=id; S.actLimit=10; render(); }}, label))));
  }
  if (!shown.length) sec.append(h("p",{class:"hint", text: q ? "Nothing matches “"+S.actQuery.trim()+"” in this time range." : "No activity yet."}));
  else sec.append(h("ul",{class:"feed"}, shown.slice(0,limit).map(e=>h("li",{},
    h("span",{class:"t", text:when(e.at)}),
    h("span",{}, h("b",{text:e.who}), e.what+" ", h("span",{class:"hint", text:"· "+e.where}))))));
  if (shown.length > limit){
    if (q) sec.append(h("p",{class:"hint", text:"Showing the newest 100 matches. Add a word to narrow it down."}));
    else if (admin) sec.append(h("button",{type:"button", class:"btn ghost small", style:"align-self:flex-start", onclick:()=>{ S.actLimit += 25; render(); }},"Show more"));
  }
  if (admin) sec.append(h("p",{class:"hint", text:"Search covers the last 60 days. Try a name and a task together, like “Jill ice wells”."}));
  return sec;
}

function canEditTask(t){ const m = me(); return canWrite() && (isAdmin() || (!!t.added_by && t.added_by===m.id)); }

/* repeat, due date and due time pickers, shared by the add and edit forms */
function scheduleFields(d, pre){
  const rec = RECURRING.has(d.repeat);
  return [
    h("label",{class:"lbl", for:pre+"Repeat"}, "Repeats",
      h("select",{id:pre+"Repeat", onchange:e=>{ d.repeat = e.target.value; if (RECURRING.has(d.repeat) && !d.due_date) d.due_date = shiftDay(); render(); }},
        REPEATS.map(([v,l])=>h("option",{value:v, selected:d.repeat===v}, l)))),
    d.repeat!=="daily" ? h("label",{class:"lbl", for:pre+"Date"}, rec ? "First due" : "Due date",
      h("input",{type:"date", id:pre+"Date", value:d.due_date||"", required:rec, oninput:e=>d.due_date=e.target.value})) : null,
    h("label",{class:"lbl", for:pre+"Time"}, d.repeat==="daily" ? "Due by (optional)" : "Time (optional)",
      h("input",{type:"time", id:pre+"Time", value:d.due_time||"", oninput:e=>d.due_time=e.target.value})),
    d.repeat!=="daily" || d.due_time ? h("p",{class:"hint full", text:scheduleHint(d)}) : null
  ];
}
function scheduleHint(d){
  const t = d.due_time ? " by "+fmtClock(d.due_time) : "";
  if (d.repeat==="daily") return "Due every shift"+t+". It's flagged overdue after that.";
  if (!d.due_date) return d.repeat==="once" ? "No due date: it stays on the list until someone checks it off." : "Pick the first due date.";
  const day = parseDay(d.due_date);
  const wd = day.toLocaleDateString(undefined,{weekday:"long"});
  const first = day.toLocaleDateString(undefined,{month:"short", day:"numeric"});
  if (d.repeat==="weekly") return "Due every "+wd+t+", starting "+first+".";
  if (d.repeat==="biweekly") return "Due every other "+wd+t+", starting "+first+".";
  if (d.repeat==="monthly") return "Due on the "+ordinal(day.getDate())+" of every month"+t+", starting "+first+". Short months use their last day.";
  return "Due "+first+t+".";
}
function editTaskForm(t, role){
  const d = S.editDraft, assignees = (roleStaff(role.id).length ? roleStaff(role.id) : D().staff).slice().sort((a,b)=>a.name.localeCompare(b.name));
  return h("form",{class:"add edit-task", onsubmit:async e=>{ e.preventDefault(); if (!d.text.trim()) return;
      if (d.repeat!=="daily" && d.repeat!=="once" && !d.due_date) return toast("Pick the first due date.");
      if (await act("api_update_task",{p_id:t.id, p_text:d.text, p_assignee:d.assignee||null, p_repeat:d.repeat, p_due_date:d.repeat==="daily" ? null : (d.due_date||null), p_due_time:d.due_time||null},"Task updated")){ S.editTask = null; render(); } }},
    h("label",{class:"lbl full", for:"edText"}, "Task", h("input",{type:"text", id:"edText", value:d.text, oninput:e=>d.text=e.target.value})),
    h("label",{class:"lbl full", for:"edAssignee"}, "For",
      h("select",{id:"edAssignee", onchange:e=>d.assignee=e.target.value},
        h("option",{value:"", selected:!d.assignee},"Anyone on this shift"),
        assignees.map(s=>h("option",{value:s.id, selected:d.assignee===s.id}, s.name)))),
    scheduleFields(d, "ed"),
    h("div",{class:"inline full"},
      h("button",{type:"submit", class:"btn small"},"Save"),
      h("button",{type:"button", class:"btn ghost small", onclick:()=>{ S.editTask = null; render(); }},"Cancel")));
}

function taskRow(t, role){
  if (S.editTask===t.id && S.editDraft) return h("div",{class:"task editing"}, editTaskForm(t, role));
  const done = isDone(t), over = isOverdue(t), due = dueLine(t), editable = canEditTask(t);
  const ck = "task:"+t.id;
  return h("div",{class:"task"+(done?" done":"")+(over?" overdue":"")+(S.fx.task===t.id ? (done?" just-done":" just-undone") : "")},
    h("button",{type:"button", class:"check", "data-own-sound":"", "aria-pressed":done?"true":"false", "aria-label":(done?"Uncheck ":"Check off ")+t.text, disabled:!canWrite(), onclick:()=>toggleTask(t)}, h("span",{}, svgCheck())),
    h("div",{style:"min-width:0"},
      h("div",{class:"text", text:t.text}),
      h("div",{class:"tmeta"},
        h("div",{class:"line"},
          h("span",{class:"tag plain", text:repeatLabel(t)}),
          t.assignee ? h("span",{class:"tag "+role.section, text:"For "+staffName(t.assignee)}) : null,
          due ? h("span",{class:"due-line "+due.cls, text:due.text}) : null),
        done ? h("div",{class:"line ok", text:"✓ Done by "+doneName(t)+" · "+when(t.done_at)}) : null,
        h("div",{class:"line"}, h("span",{text:"Added by "+addedName(t)+" · "+when(t.added_at)})),
        editable ? h("div",{class:"line"},
          h("button",{type:"button", class:"linkbtn", onclick:()=>{ S.editTask = t.id; S.editDraft = {text:t.text, assignee:t.assignee||"", repeat:t.repeat, due_date:t.due_date||"", due_time:hhmm(t.due_time)}; S.confirm = null; render(); $("edText")?.focus(); }},"Edit"),
          S.confirm===ck ? h("button",{type:"button", class:"linkbtn warn", onclick:async ()=>{ S.confirm=null; await act("api_remove_task",{p_id:t.id},"Task removed"); }},"Tap again to remove")
                         : h("button",{type:"button", class:"linkbtn", onclick:()=>askConfirm(ck)},"Remove")) : null)));
}

function viewRole(){
  const role = roleById(S.roleId);
  if (!role || !canSeeRole(role)){ S.view="overview"; return viewOverview(); }
  const people = roleStaff(role.id);
  const allTasks = roleTasks(role.id);
  let tasks = allTasks;
  const p = progressOf(allTasks.filter(countsToday));
  if (S.filter==="everyone") tasks = tasks.filter(t=>!t.assignee);
  else if (S.filter!=="all") tasks = tasks.filter(t=>t.assignee===S.filter || !t.assignee);
  const byDue = (a,b)=>(taskDeadline(a)||0)-(taskDeadline(b)||0);
  const now = tasks.filter(t=>bucket(t)==="now").sort((a,b)=>Number(isOverdue(b))-Number(isOverdue(a)) || (a.repeat==="daily")-(b.repeat==="daily"));
  const later = tasks.filter(t=>bucket(t)==="later").sort(byDue);
  const done = tasks.filter(t=>bucket(t)==="done");
  const overCount = allTasks.filter(isOverdue).length;
  const out = [];
  out.push(h("div",{class:"rolehead"},
    h("button",{type:"button", class:"back", onclick:()=>go("overview")},"← All roles"),
    h("div",{class:"sec-head", style:"margin:0"}, h("h2",{text:role.name, style:"font-size:32px"}), h("span",{class:"tag "+role.section, text:secInfo(role.section)[1]})),
    h("div",{class:"meta"}, h("span",{text: p.total ? p.done+" of "+p.total+" done today" : allTasks.length ? "Nothing due today" : "No tasks yet"}),
      p.total && p.done===p.total ? h("span",{class:"tag ok", text:"All done"}) : null,
      overCount ? h("span",{class:"tag danger", text:overCount+" overdue"}) : null),
    p.total ? bar(p.pct, "role:"+role.id) : null));
  if (people.length) out.push(h("div",{class:"chips", role:"group", "aria-label":"Show tasks for"},
    [["all","Everyone's tasks"],["everyone","Shared only"], ...people.map(s=>[s.id, s.name])].map(([id,label])=>
      h("button",{type:"button", class:"chip", "aria-pressed":S.filter===id?"true":"false", onclick:()=>{ S.filter=id; render(); }}, label))));
  if (!allTasks.length){
    const starter = STARTERS[role.id] && isAdmin() && canWrite();
    out.push(emptyCard("Nothing on this list yet",
      starter ? "Add tasks one at a time below, or start from a typical "+role.name.toLowerCase()+" list and edit it." : "Add the first task below.",
      starter ? h("button",{type:"button", class:"btn ghost", onclick:()=>act("api_add_starter_tasks",{p_role_id:role.id, p_texts:STARTERS[role.id]},"Starter list added. Edit it however you like.")},"Use a starter list") : null));
  } else {
    out.push(h("div",{class:"list"},
      now.length ? h("div",{class:"divider first", text:"To do · "+now.length}) : null,
      now.map(t=>taskRow(t, role)),
      later.length ? h("div",{class:"divider", text:"Coming up · "+later.length}) : null,
      later.map(t=>taskRow(t, role)),
      done.length ? h("div",{class:"divider", text:"Done · "+done.length}) : null,
      done.map(t=>taskRow(t, role)),
      !tasks.length ? h("div",{class:"task"}, h("span"), h("span",{class:"hint", text:"No tasks match this filter."})) : null));
  }
  const assignees = (people.length ? people : D().staff).slice().sort((a,b)=>a.name.localeCompare(b.name));
  const d = S.draft;
  out.push(h("form",{class:"add", onsubmit:async e=>{ e.preventDefault(); if (!d.text.trim()) return;
      if (RECURRING.has(d.repeat) && !d.due_date) return toast("Pick the first due date.");
      if (await act("api_add_task",{p_role_id:role.id, p_text:d.text, p_assignee:d.assignee||null, p_repeat:d.repeat, p_due_date:d.repeat==="daily" ? null : (d.due_date||null), p_due_time:d.due_time||null})){
        S.draft = {...d, text:"", due_time:"", due_date: RECURRING.has(d.repeat) ? shiftDay() : ""}; render(); $("newTask")?.focus(); } }},
    h("label",{class:"lbl full", for:"newTask"}, "New task", h("input",{type:"text", id:"newTask", placeholder:"e.g. Clean the beer lines", value:d.text, oninput:e=>d.text=e.target.value})),
    h("label",{class:"lbl full", for:"newAssignee"}, "For",
      h("select",{id:"newAssignee", onchange:e=>d.assignee=e.target.value},
        h("option",{value:"", selected:!d.assignee},"Anyone on this shift"),
        assignees.map(s=>h("option",{value:s.id, selected:d.assignee===s.id}, s.name)))),
    scheduleFields(d, "new"),
    h("button",{type:"submit", class:"btn full", disabled:!canWrite()},"Add task")));
  return out;
}

/* ---------- Inventory ---------- */
/* ---------- on tap ---------- */
const BOARD_URL = new URL("taps.html", location.href).href;
const isKeg = it => /^kegs?$/i.test((it.unit||"").trim()) || /keg/i.test((catById(it.cat_id)||{}).name || "");
const boardName = it => it.tap_label || it.name.replace(/\s+(1\/2|1\/4|1\/6|50L|30L|20L|sixtel|half|keg)$/i, "").trim();
const onTapItems = () => D().items.filter(it=>it.on_tap);
async function setOnTap(it, on){
  if (!canWrite()) return toast(errMsg({code:"offline"}));
  const before = {on_tap:it.on_tap, tapped_at:it.tapped_at};
  Object.assign(it, {on_tap:on, tapped_at: on ? new Date().toISOString() : it.tapped_at});
  play(on ? "ok" : "undo"); render();
  if (!(await act("api_set_on_tap",{p_item_id:it.id, p_on:on}, on ? boardName(it)+" is on the board" : boardName(it)+" came off the board"))){ Object.assign(it, before); render(); }
}
function tapButton(it){
  const ck = "kick:"+it.id;
  if (it.on_tap) return S.confirm===ck
    ? h("button",{type:"button", class:"tapbtn kick", "data-own-sound":"", onclick:()=>{ S.confirm=null; setOnTap(it, false); }},"Tap again: kicked")
    : h("button",{type:"button", class:"tapbtn on", "aria-pressed":"true", disabled:!canWrite(), onclick:()=>askConfirm(ck)},"On tap");
  return h("button",{type:"button", class:"tapbtn", "aria-pressed":"false", "data-own-sound":"", disabled:!canWrite(), onclick:()=>setOnTap(it, true)},"Put on tap");
}
/* top of Inventory: what's pouring, and the customer board */
function tapStrip(){
  const taps = onTapItems();
  if (!taps.length && !D().items.some(isKeg)) return null;
  return h("div",{class:"tapstrip"},
    h("div",{class:"t"},
      h("b",{text: taps.length ? taps.length+(taps.length===1?" beer":" beers")+" on tap" : "Nothing marked on tap"}),
      h("span",{class:"hint", text: taps.length ? taps.map(boardName).sort().join(", ") : "Tap “Put on tap” on a keg and it shows on the customer board."})),
    h("button",{type:"button", class:"btn small", onclick:openBoardSheet},"Board"));
}
async function loadQR(){
  if (window.qrcode) return window.qrcode;
  await new Promise((res, rej)=>{ const sc = document.createElement("script"); sc.src = "https://cdnjs.cloudflare.com/ajax/libs/qrcode-generator/1.4.4/qrcode.min.js"; sc.onload = res; sc.onerror = rej; document.head.append(sc); });
  return window.qrcode;
}
function openBoardSheet(){
  const qrBox = h("div",{class:"qrbox", "aria-label":"QR code for the on tap board"}, h("span",{class:"hint", text:"Making QR code…"}));
  openSheet(
    h("h2",{text:"On tap board"}),
    h("p",{class:"hint", text:"Customers see what's pouring right now. Open it on the bar TV or a tablet, or print the QR code for tables. It updates by itself when a keg is put on or kicked."}),
    qrBox,
    h("div",{class:"boardlink", text:BOARD_URL}),
    h("div",{class:"inline"},
      h("a",{class:"btn", href:BOARD_URL, target:"_blank", rel:"noopener"},"Open board"),
      h("button",{type:"button", class:"btn ghost", onclick:async ()=>{ try { await navigator.clipboard.writeText(BOARD_URL); toast("Link copied"); } catch(e){ toast("Press and hold the link to copy it"); } }},"Copy link")),
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Close"));
  loadQR().then(qrcode=>{
    const q = qrcode(0, "M"); q.addData(BOARD_URL); q.make();
    qrBox.innerHTML = q.createSvgTag({cellSize:6, margin:2, scalable:true});
  }).catch(()=>{ qrBox.replaceChildren(h("span",{class:"hint", text:"The QR code needs a connection. The link below works too."})); });
}

function itemRow(it){
  const st = statusOf(it), c = countOf(it.id), oh = onHandOf(it), sup = supplierById(supplierOf(it));
  return h("div",{class:"item"+(it.on_tap?" pouring":"")},
    h("div",{style:"min-width:0"},
      h("div",{class:"iname", text:it.name}),
      isKeg(it) ? h("div",{class:"imeta"}, tapButton(it), it.on_tap && it.tapped_at ? h("span",{text:"since "+when(it.tapped_at)}) : null) : null,
      h("div",{class:"imeta"},
        h("span",{class:"tag "+st.cls, text:st.text}),
        h("span",{text:"Par "+fmtN(parOf(it))+(it.unit?" "+it.unit:"")}),
        sup && isAdmin() ? h("span",{text:"· "+sup.name}) : null),
      c && c.counted_at ? h("div",{class:"imeta", text:"Counted by "+(c.counted_by_name||staffName(c.counted_by))+" · "+when(c.counted_at)}) : null),
    h("div",{class:"stepper"},
      h("button",{type:"button", "data-own-sound":"", "aria-label":"One less "+it.name, disabled:!canWrite(), onclick:()=>setCount(it, Math.max(0,(oh||0)-1))},"−"),
      h("input",{type:"number", id:"cnt-"+it.id, class:S.fx.count===it.id ? "bump" : null, inputmode:"decimal", min:"0", step:"any", "aria-label":"On hand: "+it.name, placeholder:"–", disabled:!canWrite(),
        value: oh==null ? "" : String(oh), onfocus:e=>e.target.select(),
        oninput:e=>{ if (e.target.value==="") return; setCount(it, parseFloat(e.target.value), true); }}),
      h("button",{type:"button", "data-own-sound":"", "aria-label":"One more "+it.name, disabled:!canWrite(), onclick:()=>setCount(it, (oh||0)+1)},"+")));
}
function updateItem(it, patch){
  Object.assign(it, patch); // keep quick back-to-back edits from overwriting each other
  const n = {name:it.name, unit:it.unit, par:parOf(it), supplier_id:it.supplier_id};
  return act("api_update_item",{p_id:it.id, p_name:n.name, p_unit:n.unit||"", p_par:n.par, p_supplier_id:n.supplier_id||null});
}
function listDefaultLabel(catId){
  const sup = supplierById((catById(catId)||{}).supplier_id);
  return sup ? "List default ("+sup.name+")" : "No supplier";
}
/* edit mode, top of each list: who this list is ordered from by default */
function listSupplierPicker(cat){
  const own = D().items.filter(it=>it.cat_id===cat.id && it.supplier_id).length;
  return h("div",{class:"listsup"},
    h("label",{class:"lbl", for:"lsup-"+cat.id}, "Default supplier for "+cat.name,
      h("select",{id:"lsup-"+cat.id, onchange:async e=>{ const v = e.target.value || null; cat.supplier_id = v;
          if (await act("api_set_category_supplier",{p_cat_id:cat.id, p_supplier_id:v}, v ? cat.name+" now orders from "+supplierById(v).name : "Default supplier removed")) render(); }},
        h("option",{value:"", selected:!cat.supplier_id},"None"),
        D().suppliers.map(s=>h("option",{value:s.id, selected:cat.supplier_id===s.id}, s.name)))),
    h("p",{class:"hint", text: cat.supplier_id
      ? "Every item here goes on "+(supplierById(cat.supplier_id)||{}).name+"'s order"+(own ? ", except "+own+(own===1?" item":" items")+" set to a different supplier." : ".")
      : "Pick one to send every item in this list to the same supplier. You can still change single items below."}));
}
function itemEditRow(it){
  const ck = "item:"+it.id;
  return h("div",{class:"item edit"},
    h("label",{class:"lbl wide", for:"en-"+it.id}, "Item", h("input",{type:"text", id:"en-"+it.id, value:it.name, onchange:e=>{ const v=e.target.value.trim(); if (v && v!==it.name) updateItem(it,{name:v}); }})),
    h("label",{class:"lbl", for:"eu-"+it.id}, "Unit", h("input",{type:"text", id:"eu-"+it.id, value:it.unit||"", placeholder:"cases", onchange:e=>updateItem(it,{unit:e.target.value.trim()})})),
    h("label",{class:"lbl", for:"ep-"+it.id}, "Par", h("input",{type:"number", id:"ep-"+it.id, inputmode:"decimal", min:"0", step:"any", value:parOf(it)==null?"":String(parOf(it)), placeholder:"Set", onchange:e=>{ const v=e.target.value===""?null:Number(e.target.value); updateItem(it,{par:Number.isFinite(v)?v:null}); }})),
    h("label",{class:"lbl wide", for:"es-"+it.id}, "Supplier",
      h("select",{id:"es-"+it.id, onchange:e=>updateItem(it,{supplier_id:e.target.value||null})},
        h("option",{value:"", selected:!it.supplier_id}, listDefaultLabel(it.cat_id)),
        D().suppliers.map(s=>h("option",{value:s.id, selected:it.supplier_id===s.id}, s.name)))),
    isKeg(it) ? h("label",{class:"lbl wide", for:"tl-"+it.id}, "Name on the board",
      h("input",{type:"text", id:"tl-"+it.id, value:it.tap_label||"", placeholder:boardName({...it, tap_label:""}), onchange:e=>{ it.tap_label = e.target.value.trim(); act("api_set_tap_info",{p_item_id:it.id, p_label:it.tap_label, p_note:it.tap_note||""}); }})) : null,
    isKeg(it) ? h("label",{class:"lbl wide", for:"tn-"+it.id}, "Style · ABV (on the board)",
      h("input",{type:"text", id:"tn-"+it.id, value:it.tap_note||"", placeholder:"e.g. Light lager · 4.2%", onchange:e=>{ it.tap_note = e.target.value.trim(); act("api_set_tap_info",{p_item_id:it.id, p_label:it.tap_label||"", p_note:it.tap_note}); }})) : null,
    h("div",{class:"wide", style:"grid-column:span 2;align-self:center"},
      S.confirm===ck ? h("button",{type:"button", class:"linkbtn warn", onclick:()=>{ S.confirm=null; act("api_remove_item",{p_id:it.id}, it.name+" removed"); }},"Tap again to remove "+it.name)
                     : h("button",{type:"button", class:"linkbtn", onclick:()=>askConfirm(ck)},"Remove item")));
}
function addItemForm(cat){
  const d = S.newItem[cat.id] || (S.newItem[cat.id] = {name:"", unit:"", par:"", supplier_id:""});
  return h("form",{class:"add", onsubmit:async e=>{ e.preventDefault(); if (!d.name.trim()) return;
      if (await act("api_add_items",{p_cat_id:cat.id, p_items:[{name:d.name, unit:d.unit, par:d.par, supplier_id:d.supplier_id}]})){ S.newItem[cat.id] = {name:"", unit:d.unit, par:"", supplier_id:d.supplier_id}; render(); $("ni-"+cat.id)?.focus(); } }},
    h("label",{class:"lbl full", for:"ni-"+cat.id}, "Add to "+cat.name, h("input",{type:"text", id:"ni-"+cat.id, placeholder:"Item name", value:d.name, oninput:e=>d.name=e.target.value})),
    h("label",{class:"lbl", for:"nu-"+cat.id}, "Unit", h("input",{type:"text", id:"nu-"+cat.id, placeholder:"cases", value:d.unit, oninput:e=>d.unit=e.target.value})),
    h("label",{class:"lbl", for:"np-"+cat.id}, "Par", h("input",{type:"number", id:"np-"+cat.id, inputmode:"decimal", min:"0", step:"any", value:d.par, oninput:e=>d.par=e.target.value})),
    h("label",{class:"lbl full", for:"nsu-"+cat.id}, "Supplier",
      h("select",{id:"nsu-"+cat.id, onchange:e=>d.supplier_id=e.target.value},
        h("option",{value:"", selected:!d.supplier_id}, listDefaultLabel(cat.id)),
        D().suppliers.map(s=>h("option",{value:s.id, selected:d.supplier_id===s.id}, s.name)))),
    h("button",{type:"submit", class:"btn full"},"Add item"));
}
function dayChips(selected, onToggle, idPrefix){
  return h("div",{class:"chips", role:"group", "aria-label":"Order days"}, DAYS.map((d,i)=>h("button",{type:"button", id:idPrefix+i, class:"daychip", "aria-pressed":selected.includes(i)?"true":"false", onclick:()=>onToggle(i)}, d)));
}
function saveSupplier(s, patch){
  Object.assign(s, patch);
  return act("api_save_supplier",{p_id:s.id, p_name:s.name, p_days:s.days||[], p_cutoff:s.cutoff, p_notes:s.notes,
    p_schedule:s.schedule||"weekly", p_start_date:NEEDS_START.has(s.schedule) ? (s.start_date||shiftDay()) : null});
}
/* schedule pickers for a supplier; `n` is the supplier (or the new-supplier draft), `set` saves a change */
function supScheduleFields(n, set, pre){
  return [
    h("label",{class:"lbl", for:pre+"Sched"}, "Order schedule",
      h("select",{id:pre+"Sched", onchange:e=>{ const v = e.target.value; set({schedule:v, start_date: NEEDS_START.has(v) ? (n.start_date || shiftDay()) : n.start_date}); }},
        SUP_SCHEDULES.map(([v,l])=>h("option",{value:v, selected:(n.schedule||"weekly")===v}, l)))),
    h("label",{class:"lbl", for:pre+"Cut"}, "Order by (cutoff time)", h("input",{type:"time", id:pre+"Cut", value:n.cutoff||"14:00", onchange:e=>{ if (e.target.value) set({cutoff:e.target.value}); }})),
    (n.schedule||"weekly")==="weekly" ? h("div",{class:"lbl full"}, "Order days", dayChips(n.days||[], i=>{ const st = new Set(n.days||[]); st.has(i)?st.delete(i):st.add(i); set({days:[...st].sort()}); }, pre+"Day")) : null,
    NEEDS_START.has(n.schedule) ? h("label",{class:"lbl full", for:pre+"Start"}, n.schedule==="once" ? "Order date" : "First order date",
      h("input",{type:"date", id:pre+"Start", value:n.start_date||"", onchange:e=>{ if (e.target.value) set({start_date:e.target.value}); }})) : null,
    h("p",{class:"hint full", text:supScheduleHint({...n, schedule:n.schedule||"weekly"})})
  ];
}
function supplierEditCard(s){
  const ck = "sup:"+s.id;
  return h("div",{class:"card"},
    h("label",{class:"lbl", for:"sn-"+s.id}, "Supplier", h("input",{type:"text", id:"sn-"+s.id, value:s.name, onchange:e=>{ const v=e.target.value.trim(); if (v && v!==s.name) saveSupplier(s,{name:v}); }})),
    h("div",{class:"supgrid"}, supScheduleFields(s, patch=>saveSupplier(s, patch), "s"+s.id+"-")),
    h("label",{class:"lbl", for:"so-"+s.id}, "Notes", h("input",{type:"text", id:"so-"+s.id, value:s.notes||"", placeholder:"Rep name, phone, how to order", onchange:e=>saveSupplier(s,{notes:e.target.value.trim()})})),
    h("div",{}, S.confirm===ck ? h("button",{type:"button", class:"linkbtn warn", onclick:()=>{ S.confirm=null; act("api_remove_supplier",{p_id:s.id}, s.name+" removed"); }},"Tap again to remove "+s.name)
                               : h("button",{type:"button", class:"linkbtn", onclick:()=>askConfirm(ck)},"Remove supplier")));
}
function supplierOrderCard(s, d){
  const items = belowPar(s.id), ordered = orderedThisRound(s), soon = d && d - new Date() < 24*3600e3;
  const once = (s.schedule||"weekly")==="once", missed = once && !d && !ordered && !!s.start_date;
  const dueAt = d || (once && s.start_date ? atCutoff(parseDay(s.start_date), s.cutoff) : null);
  const stamp = x => x.toLocaleDateString(undefined,{weekday:"short", month:"short", day:"numeric"})+", "+x.toLocaleTimeString(undefined,{hour:"numeric", minute:"2-digit"});
  const dueTextLine = ordered ? (d ? "Ordered for "+dueText(d) : dueAt ? "Was due "+stamp(dueAt) : "")
                    : missed ? "Missed · was due "+stamp(dueAt)
                    : d ? "Order by "+dueText(d) : "No order days set";
  return h("div",{class:"card"+(!ordered && (missed || (soon && items.length)) ? " urgent" : "")+(ordered ? " ordered" : "")},
    h("div",{class:"row"}, h("h3",{text:s.name}),
      h("span",{class:"tag "+(ordered ? "ok" : missed ? "danger" : items.length ? "warn" : "ok"), text: ordered ? "Ordered" : missed ? "Missed" : items.length ? items.length+" to order" : "Nothing low"})),
    h("div",{class:"line"}, h("span",{class:"tag plain", text:supScheduleLabel(s)})),
    h("div",{class:"due"+(!ordered && (soon || missed) ? " soon" : ""), text:dueTextLine}),
    s.notes ? h("p",{class:"hint", text:s.notes}) : null,
    !ordered && items.length ? h("ul",{class:"orderlines"}, items.map(it=>h("li",{}, h("span",{text:it.name}), h("span",{class:"q", text:fmtN(needOf(it))+(it.unit?" "+it.unit:"")})))) : null,
    s.last_ordered_at ? h("p",{class:"hint", text:(ordered ? "Ordered by " : "Last order placed by ")+(s.last_ordered_by_name||"someone")+" · "+when(s.last_ordered_at)}) : null,
    !ordered ? h("div",{class:"inline"},
      items.length ? h("button",{type:"button", class:"btn ghost small", onclick:()=>sendOrder(s.name, items)}, navigator.share ? "Send order" : "Copy order") : null,
      canWrite() ? h("button",{type:"button", class:"btn small", "data-own-sound":"", onclick:async ()=>{ if (await act("api_mark_ordered",{p_id:s.id},"Marked as ordered")) play("ok"); }},"Mark order placed") : null) : null);
}
/* managers: narrow every list to one supplier (Origlio, Penn, Muller...) */
const shortName = n => n.replace(/\s*\(.*?\)\s*/g," ").trim().split(/\s+/)[0];
function supplierChips(){
  if (!isAdmin()) return null;
  const used = new Set(D().items.map(supplierOf).filter(Boolean));
  const sups = D().suppliers.filter(s=>used.has(s.id)).sort((a,b)=>a.name.localeCompare(b.name));
  if (!sups.length) return null;
  if (S.invSup && !used.has(S.invSup)) S.invSup = null;
  return h("div",{class:"chips supchips", role:"group", "aria-label":"Show items from supplier"},
    h("button",{type:"button", class:"chip", "aria-pressed":!S.invSup?"true":"false", onclick:()=>{ S.invSup = null; render(); }},"All suppliers"),
    sups.map(sp=>h("button",{type:"button", class:"chip", title:sp.name, "aria-pressed":S.invSup===sp.id?"true":"false", onclick:()=>{ S.invSup = S.invSup===sp.id ? null : sp.id; render(); }}, shortName(sp.name))));
}
function viewInventory(){
  const admin = isAdmin(), out = [], d = D();
  if (!admin) S.invEdit = false;
  out.push(h("div",{class:"rolehead"},
    h("div",{class:"sec-head", style:"margin:0"}, h("h2",{text:"Inventory", style:"font-size:32px"}),
      admin && d.invcats.length ? h("button",{type:"button", class:"btn "+(S.invEdit?"":"ghost")+" small", onclick:()=>{ S.invEdit=!S.invEdit; S.confirm=null; render(); }}, S.invEdit ? "Done editing" : "Edit lists & pars") : null),
    h("p",{class:"hint", text: S.invEdit ? "Set each item's par (how much should be on the shelf), its unit and who you order it from." : admin ? "Count what's on the shelf. Anything under par goes on that supplier's order." : "Count what's on the shelf. Managers use your counts to place orders."})));
  if (!d.invcats.length){
    out.push(admin ? h("form",{class:"inline", onsubmit:async e=>{ e.preventDefault(); if (await act("api_add_category",{p_name:S.newCat})){ S.newCat=""; render(); } }},
        h("input",{type:"text", id:"newCat", placeholder:"New list, e.g. Bar supplies", "aria-label":"New list name", value:S.newCat, oninput:e=>S.newCat=e.target.value}),
        h("button",{type:"submit", class:"btn"},"Add list"))
      : emptyCard("No inventory lists yet", "A manager needs to set up the inventory lists first."));
    return out;
  }

  if (!S.invEdit){ const ts = tapStrip(); if (ts) out.push(ts); }

  /* suppliers: order deadlines (count mode) or supplier settings (edit mode) */
  if (S.invEdit){
    out.push(fold("suppliers-edit", true, "Suppliers & deadlines", h("span",{class:"tag plain", text:d.suppliers.length+(d.suppliers.length===1?" supplier":" suppliers")}), [
      d.suppliers.map(supplierEditCard),
      h("form",{class:"add", onsubmit:async e=>{ e.preventDefault(); const n = S.newSup; if (!n.name.trim()) return;
          if (await act("api_save_supplier",{p_id:null, p_name:n.name, p_days:[...n.days].sort(), p_cutoff:n.cutoff, p_notes:n.notes,
                p_schedule:n.schedule, p_start_date:NEEDS_START.has(n.schedule) ? (n.start_date||shiftDay()) : null}, n.name.trim()+" added")){
            S.newSup = {name:"", days:[], cutoff:"14:00", notes:"", schedule:"weekly", start_date:""}; render(); } }},
        h("label",{class:"lbl full", for:"nsName"}, "New supplier", h("input",{type:"text", id:"nsName", placeholder:"e.g. Restaurant Depot", value:S.newSup.name, oninput:e=>S.newSup.name=e.target.value})),
        supScheduleFields(S.newSup, patch=>{ Object.assign(S.newSup, patch); render(); }, "ns"),
        h("label",{class:"lbl full", for:"nsNotes"}, "Notes", h("input",{type:"text", id:"nsNotes", placeholder:"Rep, phone", value:S.newSup.notes, oninput:e=>S.newSup.notes=e.target.value})),
        h("button",{type:"submit", class:"btn full"},"Add supplier"))]));
  } else if (admin){
    const rows = suppliersByDeadline();
    const toPlace = rows.filter(x=>!x.ordered && belowPar(x.s.id).length).length;
    const loose = belowPar(null).filter(it=>!supplierById(supplierOf(it)));
    const next = rows.find(x=>x.d && !x.ordered);
    const badge = toPlace ? h("span",{class:"tag warn", text:toPlace+(toPlace===1?" order to place":" orders to place")})
                : next ? h("span",{class:"tag plain", text:"Next: "+next.s.name.split(" ")[0]+" "+next.d.toLocaleDateString(undefined,{weekday:"short"})})
                : h("span",{class:"tag ok", text:"All caught up"});
    const body = [h("p",{class:"hint", text:"Only managers see this section."})];
    if (!d.suppliers.length) body.push(h("p",{class:"hint", text:"Add your suppliers and their order schedules under Edit lists & pars. Each one gets a countdown and an order list built from your counts."}));
    else for (const {s, d:dl} of rows) body.push(supplierOrderCard(s, dl));
    if (loose.length) body.push(h("div",{class:"card"},
      h("div",{class:"row"}, h("h3",{text:"No supplier set"}), h("span",{class:"tag warn", text:loose.length+" to order"})),
      h("ul",{class:"orderlines"}, loose.map(it=>h("li",{}, h("span",{text:it.name}), h("span",{class:"q", text:fmtN(needOf(it))+(it.unit?" "+it.unit:"")})))),
      h("div",{class:"inline"}, h("button",{type:"button", class:"btn ghost small", onclick:()=>sendOrder("Supply", loose)}, navigator.share ? "Send list" : "Copy list"))));
    out.push(fold("orders", true, "Order deadlines", badge, body));
  }

  /* search and filters */
  const q = S.invQuery.trim().toLowerCase();
  const filter = S.invEdit ? "all" : S.invFilter;
  out.push(h("div",{class:"invtools"},
    h("div",{class:"searchbox"},
      h("input",{type:"search", id:"invSearch", placeholder:"Search items", "aria-label":"Search inventory items", autocomplete:"off", enterkeyhint:"search",
        value:S.invQuery, oninput:e=>{ S.invQuery = e.target.value; render(); }}),
      S.invQuery ? h("button",{type:"button", class:"clearsearch", "aria-label":"Clear search", onclick:()=>{ S.invQuery = ""; render(); $("invSearch")?.focus(); }},"×") : null),
    S.invEdit ? null : h("div",{class:"chips", role:"group", "aria-label":"Show items"},
      [["all","All items"],["low","Needs ordering"],["uncounted","Not counted"]].map(([id,label])=>
        h("button",{type:"button", class:"chip", "aria-pressed":S.invFilter===id?"true":"false", onclick:()=>{ S.invFilter=id; render(); }}, label))),
    supplierChips()));

  /* the lists */
  const supSel = admin && S.invSup && supplierById(S.invSup) ? S.invSup : null;
  const narrowing = !!q || filter!=="all" || !!supSel;
  let shownLists = 0;
  for (const cat of d.invcats){
    const all = catItems(cat.id);
    let items = all.filter(it=>matchesQuery(it, q));
    if (filter==="low") items = items.filter(it=>(needOf(it)||0)>0);
    if (filter==="uncounted") items = items.filter(it=>onHandOf(it)==null);
    if (supSel) items = items.filter(it=>supplierOf(it)===supSel);
    if (narrowing && !items.length) continue;          // hide lists with nothing to show
    shownLists++;
    const low = all.filter(it=>(needOf(it)||0)>0).length, total = all.length;
    const pouring = all.filter(it=>it.on_tap).length;
    const badge = narrowing ? h("span",{class:"tag plain", text:items.length+(items.length===1?" match":" matches")})
                : low ? h("span",{class:"tag warn", text:low+" below par"})
                : pouring ? h("span",{class:"tag ok", text:pouring+" on tap"})
                : h("span",{class:"tag plain", text:total+(total===1?" item":" items")});
    const ck = "cat:"+cat.id, body = [];
    if (S.invEdit && !narrowing) body.push(listSupplierPicker(cat));
    if (!total){
      const starter = INV_STARTERS[cat.id] && admin && canWrite();
      body.push(emptyCard("Nothing on this list yet", starter ? "Add items one by one, or start with common "+cat.name.toLowerCase()+" and set your own pars." : admin ? "Add the first item below." : "A manager needs to add items to this list.",
        starter ? h("button",{type:"button", class:"btn ghost", onclick:async ()=>{ if (await act("api_add_items",{p_cat_id:cat.id, p_items:INV_STARTERS[cat.id].map(([name,unit])=>({name, unit}))},"Starter items added. Set a par for each one.")){ S.invEdit = true; render(); } }},"Use a starter list") : null));
    } else body.push(h("div",{class:"list"}, items.map(S.invEdit ? itemEditRow : itemRow)));
    if (S.invEdit && !narrowing){
      body.push(addItemForm(cat));
      body.push(h("div",{}, S.confirm===ck ? h("button",{type:"button", class:"linkbtn warn", onclick:()=>{ S.confirm=null; act("api_remove_category",{p_id:cat.id}, cat.name+" removed"); }},"Tap again: removes "+cat.name+" and its "+total+" items")
                                         : h("button",{type:"button", class:"linkbtn", onclick:()=>askConfirm(ck)},"Remove the "+cat.name+" list")));
    }
    out.push(fold("list:"+cat.id, false, cat.name, badge, body, {forced:narrowing}));
  }
  if (narrowing && !shownLists){
    const from = supSel ? " from "+supplierById(supSel).name : "";
    out.push(h("p",{class:"hint empty-search", text: q ? "No items"+from+" match “"+S.invQuery.trim()+"”"+(filter==="low" ? " that need ordering." : filter==="uncounted" ? " that still need counting." : ".")
                                                     : filter==="low" ? "Nothing"+from+" needs ordering right now." : filter==="uncounted" ? "Everything"+from+" has been counted." : "No items"+from+" yet."}));
  }
  if (S.invEdit && !narrowing){
    out.push(h("form",{class:"inline", onsubmit:async e=>{ e.preventDefault(); if (await act("api_add_category",{p_name:S.newCat})){ S.newCat=""; render(); } }},
      h("input",{type:"text", id:"newCat", placeholder:"New list, e.g. Cleaning supplies", "aria-label":"New list name", value:S.newCat, oninput:e=>S.newCat=e.target.value}),
      h("button",{type:"submit", class:"btn"},"Add list")));
  }
  return out;
}

/* ---------- Team ---------- */
/* devices seen in the last 30 days, newest first */
function devicesOf(staffId){ const cut = Date.now() - 30*86400e3; return (S.versions||[]).filter(v=>v.staff_id===staffId && new Date(v.seen_at).getTime() > cut); }
function personVersions(s){
  if (!S.versions || !s.has_login) return null;
  const devs = devicesOf(s.id), latest = latestVersion();
  if (!devs.length) return h("div",{class:"devices"}, h("div",{class:"dev"},
    h("span",{class:"tag warn", text:"Not on version "+latest+" yet"}),
    h("span",{class:"hint", text:"Hasn't opened the latest app. Ask them to close it and reopen."})));
  return h("div",{class:"devices"}, devs.map(v=>h("div",{class:"dev"},
    h("span",{class:"tag "+(v.version>=latest?"ok":"warn"), text: v.version>=latest ? "Up to date" : "Needs update"}),
    h("span",{class:"hint", text:"Version "+v.version+" · "+(v.platform||"Device")+" · last open "+when(v.seen_at)}))));
}
function versionSummary(){
  if (!S.versions) return h("p",{class:"hint", text:"Checking which version everyone is on…"});
  const latest = latestVersion();
  const people = D().staff.filter(s=>s.has_login);
  const current = people.filter(s=>{ const devs = devicesOf(s.id); return devs.length && devs.every(v=>v.version>=latest); });
  const behind = people.length - current.length;
  return h("div",{class:"vsummary"+(behind?" behind":"")},
    h("b",{text: behind ? current.length+" of "+people.length+" on the latest version" : "Everyone is on the latest version"}),
    h("span",{class:"hint", text:"Version "+latest+(S.latest && S.latest.date ? " · released "+fmtVersionDate(S.latest.date) : "")+". " +
      (behind ? "To update, close the app fully and reopen it. Check-ins show up the next time each person opens the app." : "")}));
}

function loginControl(s){
  const ck = "nopin:"+s.id;
  if (S.pinEdit===s.id){
    return h("form",{class:"pinform", onsubmit:e=>{ e.preventDefault(); saveNumber(s); }},
      h("label",{class:"lbl", for:"pin-"+s.id}, (s.has_login ? "New" : "Assign a")+" login number",
        h("div",{class:"inline"},
          h("input",{type:"text", id:"pin-"+s.id, inputmode:"numeric", autocomplete:"off", maxlength:"6", placeholder:"4–6 digits", value:S.pinDraft, oninput:e=>{ e.target.value = e.target.value.replace(/\D/g,""); S.pinDraft = e.target.value; }}),
          h("button",{type:"button", class:"btn ghost small", onclick:()=>{ S.pinDraft = randomNumber(); render(); }},"Random"))),
      S.pinErr ? h("p",{class:"loginerr", role:"alert", text:S.pinErr}) : null,
      h("div",{class:"inline"},
        h("button",{type:"submit", class:"btn small", disabled:S.pinBusy}, S.pinBusy ? "Saving…" : "Save number"),
        h("button",{type:"button", class:"btn ghost small", onclick:()=>{ S.pinEdit=null; S.pinDraft=""; S.pinErr=""; render(); }},"Cancel")));
  }
  return h("div",{class:"row pinrow"},
    h("span",{class:"hint", text: s.has_login ? "Login number set by "+(s.login_set_by||"a manager")+" · "+when(s.login_set_at) : "No login number yet. "+s.name+" can't log in."}),
    h("span",{class:"inline"},
      h("button",{type:"button", class:"btn "+(s.has_login?"ghost ":"")+"small", onclick:()=>{ S.pinEdit=s.id; S.pinDraft=""; S.pinErr=""; render(); $("pin-"+s.id)?.focus(); }}, s.has_login ? "Change number" : "Assign number"),
      s.has_login ? (S.confirm===ck ? h("button",{type:"button", class:"linkbtn warn", onclick:()=>{ S.confirm=null; act("api_clear_pin",{p_id:s.id}, s.name+" can no longer log in"); }},"Tap again to turn off")
                                    : h("button",{type:"button", class:"linkbtn", onclick:()=>askConfirm(ck)},"Turn off login")) : null));
}
function viewTeam(){
  if (!isAdmin()){ S.view="overview"; return viewOverview(); }
  const d = D(), out = [];
  out.push(h("section",{class:"stack"},
    h("div",{class:"sec-head"}, h("h2",{text:"Team"}), h("span",{class:"hint", text:d.staff.length+" "+(d.staff.length===1?"person":"people")})),
    versionSummary(),
    h("p",{class:"hint", text:"Everyone logs in with the number you assign here. Only people with the Manager role get manager controls: this Team tab, inventory pars and suppliers, order deadlines, and starter lists."}),
    h("form",{class:"inline", onsubmit:async e=>{ e.preventDefault(); const n = S.newPerson.trim(); if (!n) return; if (await act("api_add_staff",{p_name:n}, n+" added")){ S.newPerson=""; render(); } }},
      h("input",{type:"text", id:"newPerson", placeholder:"Add a person by name", "aria-label":"Name", value:S.newPerson, oninput:e=>S.newPerson=e.target.value}),
      h("button",{type:"submit", class:"btn"},"Add")),
    d.staff.slice().sort((a,b)=>Number(isManagerStaff(b))-Number(isManagerStaff(a))||a.name.localeCompare(b.name)).map(s=>{
      const ck = "staff:"+s.id;
      return h("div",{class:"person"},
        h("div",{class:"row"}, h("span",{class:"pname", text:s.name}), isManagerStaff(s) ? h("span",{class:"tag mgmt", text:"Manager"}) : null),
        personVersions(s),
        h("div",{class:"chips"}, sortedRoles().map(r=>h("button",{type:"button", class:"rolechip "+r.section, "aria-pressed":(s.roles||[]).includes(r.id)?"true":"false",
          onclick:()=>{ const set = new Set(s.roles||[]); set.has(r.id)?set.delete(r.id):set.add(r.id); act("api_set_staff_roles",{p_id:s.id, p_roles:[...set]}); }}, r.name))),
        loginControl(s),
        h("div",{}, S.confirm===ck ? h("button",{type:"button", class:"linkbtn warn", onclick:()=>{ S.confirm=null; act("api_remove_staff",{p_id:s.id}, s.name+" removed"); }},"Tap again to remove "+s.name)
                                   : h("button",{type:"button", class:"linkbtn", onclick:()=>askConfirm(ck)},"Remove from team")));
    })));
  out.push(h("section",{class:"stack"},
    h("div",{class:"sec-head"}, h("h2",{text:"Roles"})),
    h("div",{class:"rows"}, sortedRoles().map(r=>{
      const ck = "role:"+r.id;
      return h("div",{class:"role"},
        h("span",{class:"name", text:r.name}),
        h("span",{class:"count"}, h("span",{class:"tag "+r.section, text:secInfo(r.section)[2]})),
        h("span",{}, S.confirm===ck ? h("button",{type:"button", class:"linkbtn warn", onclick:()=>{ S.confirm=null; act("api_remove_role",{p_id:r.id},"Role removed"); }},"Tap again: removes the role and its "+roleTasks(r.id).length+" tasks")
                                    : h("button",{type:"button", class:"linkbtn", onclick:()=>askConfirm(ck)},"Remove role")));
    })),
    h("form",{class:"add", onsubmit:async e=>{ e.preventDefault(); if (!S.newRole.trim()) return; if (await act("api_add_role",{p_name:S.newRole, p_section:S.newRoleSection},"Role added")){ S.newRole=""; render(); } }},
      h("label",{class:"lbl full", for:"newRole"}, "New role", h("input",{type:"text", id:"newRole", placeholder:"e.g. Server", value:S.newRole, oninput:e=>S.newRole=e.target.value})),
      h("label",{class:"lbl", for:"newRoleSection"}, "Section",
        h("select",{id:"newRoleSection", onchange:e=>S.newRoleSection=e.target.value},
          SECTIONS.map(([id,label])=>h("option",{value:id, selected:S.newRoleSection===id}, label)))),
      h("button",{type:"submit", class:"btn", style:"align-self:end"},"Add role"))));
  return out;
}

/* ---------- render ---------- */
function renderOffline(){
  const el = $("offline");
  el.hidden = !S.offline;
  el.textContent = S.offline ? "You're offline. " + (S.dataAt ? "Showing info from " + when(S.dataAt) + ". " : "") + "Changes can't be saved until you reconnect." : "";
}
function renderUpdateBar(){
  const show = updateReady() && !!S.session;
  $("updatebar").hidden = !show;
  if (show){ $("updatetext").textContent = "Version "+S.latest.version+" of the app is ready."; $("updateBtn").disabled = S.updating; $("updateBtn").textContent = S.updating ? "Updating…" : "Update now"; }
}
function render(){
  $("dayLabel").textContent = shiftDayLabel();
  renderOffline();
  renderUpdateBar();
  $("installBtn").hidden = !S.installEvent || !S.session;
  const m = me(), loggedIn = !!(S.session && m);
  $("whoBtn").hidden = !loggedIn;
  $("whoName").textContent = loggedIn ? m.name + (m.manager ? " · Mgr" : "") : "";
  $("whoDot").textContent = loggedIn ? initials(m.name) : "?";
  $("tabs").hidden = !loggedIn;
  let kids;
  if (!configured()) kids = viewNotConfigured();
  else if (!S.session) kids = viewLogin();
  else if (!m) kids = [h("p",{class:"hint", text: S.offline ? "You're offline. Connect once to load your lists." : "Loading…"})];
  else {
    const admin = isAdmin();
    $("tabTeam").hidden = !admin;
    if (!admin && S.view==="team") S.view = "overview";
    const tab = S.view==="team" ? "team" : S.view==="inventory" ? "inventory" : "shifts";
    $("tabShifts").setAttribute("aria-pressed", String(tab==="shifts"));
    $("tabInv").setAttribute("aria-pressed", String(tab==="inventory"));
    $("tabTeam").setAttribute("aria-pressed", String(tab==="team"));
    kids = S.view==="role" ? viewRole() : S.view==="team" ? viewTeam() : S.view==="inventory" ? viewInventory() : S.view==="notify" ? viewNotify() : viewOverview();
  }
  const active = document.activeElement, aid = active && active.id;
  let sel = null; try { if (aid && active.selectionStart != null) sel = [active.selectionStart, active.selectionEnd]; } catch(e){}
  $("view").replaceChildren(...kids);
  afterRender();
  if (aid){ const el = $(aid); if (el && el !== active){ el.focus(); if (sel && el.setSelectionRange) try { el.setSelectionRange(sel[0], sel[1]); } catch(e){} } }
}

/* ---------- wiring ---------- */
$("whoBtn").addEventListener("click", openAccount);
$("installBtn").addEventListener("click", install);
$("updateBtn").addEventListener("click", applyUpdate);
$("tabShifts").addEventListener("click", ()=>go("overview"));
$("tabInv").addEventListener("click", ()=>go("inventory"));
$("tabTeam").addEventListener("click", ()=>{ go("team"); loadVersions(); });
document.addEventListener("keydown", e=>{
  if (S.session || !document.querySelector(".keypad") || e.target.matches("input,select,textarea")) return;
  if (/^\d$/.test(e.key)) pressKey(e.key); else if (e.key==="Backspace") pressKey("del"); else if (e.key==="Enter") pressKey("go");
});
document.addEventListener("visibilitychange", ()=>{ if (!document.hidden){ refresh(); checkLatest(); render(); } });
window.addEventListener("online", ()=>{ setOffline(false); refresh(); });
window.addEventListener("offline", ()=>setOffline(true));
window.addEventListener("beforeinstallprompt", e=>{ e.preventDefault(); S.installEvent = e; render(); });
window.addEventListener("appinstalled", ()=>{ S.installEvent = null; render(); toast("Installed. Open Brewskis from your home screen."); });
setInterval(()=>{
  if (document.hidden || !S.session) return;
  const typing = document.activeElement && document.activeElement.matches && document.activeElement.matches("input,select,textarea");
  if (!typing && !Object.keys(S.countDraft).length) refresh();
}, POLL_MS);
setInterval(()=>{ if (!document.hidden && !(document.activeElement && document.activeElement.matches && document.activeElement.matches("input,select,textarea"))) render(); }, 60000);

if ("serviceWorker" in navigator && (location.protocol === "https:" || location.hostname === "localhost" || location.hostname === "127.0.0.1")){
  navigator.serviceWorker.register("sw.js").catch(()=>{});
}

/* intro: about a second and a half on opening the app; tap to skip */
(function intro(){
  const el = $("intro"); if (!el) return;
  if (document.documentElement.classList.contains("no-intro")){ el.remove(); return; }
  try { sessionStorage.setItem("brewskis.intro", "1"); } catch(e){}
  const reduce = window.matchMedia("(prefers-reduced-motion: reduce)").matches;
  const start = performance.now();
  let wooshed = false;
  /* the woosh only plays where the phone allows sound before the first tap (Android, installed app).
     iPhones never do, so there it plays if you tap to skip the intro instead. */
  if (soundOn && !reduce){
    const ctx = audio();
    if (ctx) ctx.resume().then(()=>{
      if (ctx.state!=="running" || el.classList.contains("out") || wooshed) return;
      wooshed = true;
      SOUNDS.woosh(ctx, ctx.destination, ctx.currentTime + Math.max(0, .55 - (performance.now()-start)/1000), .9);
    }).catch(()=>{});
  }
  const done = () => { if (!el.isConnected || el.classList.contains("out")) return; el.classList.add("out"); setTimeout(()=>el.remove(), 350); };
  setTimeout(done, reduce ? 700 : 1650);
  el.addEventListener("click", ()=>{ if (!wooshed && !el.classList.contains("out")){ wooshed = true; play("wooshQuick"); } done(); });
})();

(function boot(){
  S.session = loadSession();
  if (S.session){
    try { const c = JSON.parse(localStorage.getItem(CACHE_KEY)||"null"); if (c && c.token===S.session.token){ S.data = c.data; S.dataAt = c.at; } } catch(e){}
  }
  if (location.hash==="#inventory") S.view = "inventory";   // opened from an order or out-of-stock notification
  render();
  if (S.session && configured()) refresh();
  checkLatest(true);
})();
window.addEventListener("hashchange", ()=>{ if (location.hash==="#inventory" && S.session){ go("inventory"); } });
