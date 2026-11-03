/* JT Brewski's staff app · Drawing the screen, wiring up the buttons, and starting the app. */
"use strict";

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
  renderOffline();
  renderUpdateBar();
  $("installBtn").hidden = !S.installEvent || !S.session;
  const m = me(), loggedIn = !!(S.session && m);
  $("whoBtn").hidden = !loggedIn;
  $("settingsBtn").hidden = !loggedIn;
  $("settingsBtn").setAttribute("aria-pressed", String(S.view==="settings" || S.view==="team" || (S.view==="notify" && S.notifyBack==="settings")));
  $("whoName").textContent = loggedIn ? m.name + (m.manager ? " · Mgr" : "") : "";
  $("whoDot").textContent = loggedIn ? initials(m.name) : "?";
  $("tabs").hidden = !loggedIn;
  let kids;
  if (!configured()) kids = viewNotConfigured();
  else if (!S.session) kids = viewLogin();
  else if (!m) kids = S.offline ? [h("p",{class:"hint", text:"You're offline. Connect once to load your lists."})] : skeleton("home");
  else {
    const admin = isAdmin();
    if (!admin && S.view==="team") S.view = "overview";
    if (S.view==="cash" && !showCashTab()) S.view = "overview";
    const tv = S.view==="notify" ? (S.notifyBack || "overview") : S.view;
    const tab = tv==="settings" || tv==="team" ? "settings" : tv==="inventory" ? "inventory" : tv==="schedule" ? "schedule" : tv==="events" ? "events" : tv==="cash" ? "cash" : "shifts";
    $("tabSched").setAttribute("aria-pressed", String(tab==="schedule"));
    $("tabSched").classList.toggle("has-dot", forYouShifts().length > 0);
    $("tabShifts").setAttribute("aria-pressed", String(tab==="shifts"));
    $("tabInv").setAttribute("aria-pressed", String(tab==="inventory"));
    $("tabEvents").setAttribute("aria-pressed", String(tab==="events"));
    $("tabCash").hidden = !showCashTab();
    $("tabCash").setAttribute("aria-pressed", String(tab==="cash"));
    $("tabCash").classList.toggle("has-dot", tab!=="cash" && cashDot());
    kids = S.view==="team" ? viewTeam() : S.view==="cash" ? viewCash() : S.view==="inventory" ? viewInventory() : S.view==="notify" ? viewNotify() : S.view==="settings" ? viewSettings() : S.view==="schedule" ? viewSchedule() : S.view==="events" ? viewEvents() : viewOverview();
  }
  const active = document.activeElement, aid = active && active.id;
  let sel = null; try { if (aid && active.selectionStart != null) sel = [active.selectionStart, active.selectionEnd]; } catch(e){}
  $("view").replaceChildren(...kids);
  afterRender();
  if (aid){ const el = $(aid); if (el && el !== active){ el.focus(); if (sel && el.setSelectionRange) try { el.setSelectionRange(sel[0], sel[1]); } catch(e){} } }
}

/* ---------- wiring ---------- */
$("whoBtn").addEventListener("click", ()=>{ if (!["settings","team","notify"].includes(S.view)) S.settingsBack = S.view; go("settings"); });
$("settingsBtn").addEventListener("click", ()=>{
  if (S.view==="settings" || S.view==="team") return go(S.settingsBack || "overview");   // tap again: back to the tab you were on
  if (S.view!=="notify") S.settingsBack = S.view;
  go("settings");
});
$("installBtn").addEventListener("click", install);
$("updateBtn").addEventListener("click", applyUpdate);
$("tabShifts").addEventListener("click", ()=>go("overview"));
$("tabInv").addEventListener("click", ()=>go("inventory"));
$("tabSched").addEventListener("click", ()=>go("schedule"));
$("tabEvents").addEventListener("click", ()=>go("events"));
$("tabCash").addEventListener("click", ()=>go("cash"));
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
  if (!typing && !openDrop && !Object.keys(S.countDraft).length) refresh();
}, POLL_MS);
setInterval(()=>{ if (!document.hidden && !openDrop && !(document.activeElement && document.activeElement.matches && document.activeElement.matches("input,select,textarea"))) render(); }, 60000);

if ("serviceWorker" in navigator && (location.protocol === "https:" || location.hostname === "localhost" || location.hostname === "127.0.0.1")){
  navigator.serviceWorker.register("sw.js").catch(()=>{});
}

/* no zooming: iPhones ignore the page's no-zoom setting, so stop the pinch gesture itself */
["gesturestart","gesturechange","gestureend"].forEach(t=>document.addEventListener(t, e=>e.preventDefault(), {passive:false}));
document.addEventListener("touchmove", e=>{ if (e.touches.length > 1 || (e.scale && e.scale !== 1)) e.preventDefault(); }, {passive:false});

/* pull down at the top of the screen to refresh */
(function pullToRefresh(){
  const ind = h("div",{class:"ptr", "aria-hidden":"true"}, h("span",{class:"ptr-spin"}));
  document.body.append(ind);
  const TRIGGER = 64, MAX = 96;
  let y0 = null, pull = 0, busy = false;
  const set = px => { ind.style.transform = "translate(-50%,"+(px - 52)+"px)"; ind.style.opacity = String(Math.min(1, px/TRIGGER));
                      ind.firstChild.style.transform = "rotate("+(px*4)+"deg)"; ind.classList.toggle("ready", px >= TRIGGER); };
  const blocked = e => !S.session || busy || !$("sheet").hidden || window.scrollY > 2 || document.getElementById("intro") ||
                       (e.target.closest && e.target.closest("input,textarea,select,.keypad"));
  addEventListener("touchstart", e=>{ y0 = (e.touches.length===1 && !blocked(e)) ? e.touches[0].clientY : null; pull = 0; }, {passive:true});
  addEventListener("touchmove", e=>{
    if (y0==null) return;
    const dy = e.touches[0].clientY - y0;
    if (dy <= 0 || window.scrollY > 2){ pull = 0; set(0); return; }
    pull = Math.min(MAX, dy * .5); set(pull);
  }, {passive:true});
  addEventListener("touchend", async ()=>{
    if (y0==null) return; y0 = null;
    if (pull >= TRIGGER){
      busy = true; ind.classList.add("spin"); set(TRIGGER); play("tap");
      await Promise.all([refresh(), Promise.resolve(checkLatest()).catch(()=>{}), new Promise(r=>setTimeout(r, 700))]);
      busy = false; ind.classList.remove("spin");
    }
    pull = 0; set(0);
  });
  set(0);
})();

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
  if (location.hash==="#schedule") S.view = "schedule";     // opened from a shift swap notification
  if (location.hash==="#events") S.view = "events";
  if (location.hash==="#cash") S.view = "cash";   // a drawer came up short
  if (location.hash==="#dailycash"){ S.view = "cash"; setTimeout(scrollToDailyCash, 1500); }
  if (location.hash==="#alerts"){ S.view = "overview"; setTimeout(scrollToAlerts, 1500); }   // an alert from staff
  render();
  if (S.session && configured()) refresh();
  checkLatest(true).then(()=>autoUpdate(0));
  try { const u = sessionStorage.getItem("brewskis.updated"); if (u){ sessionStorage.removeItem("brewskis.updated");
    const v = sessionStorage.getItem("brewskis.view"); sessionStorage.removeItem("brewskis.view");
    if (v && ["overview","inventory","schedule","events","cash","settings","team"].includes(v) && !location.hash){ S.view = v; render(); } setTimeout(()=>toast("Updated to version "+(u || APP_VERSION)+" ✓"), 1900); } } catch(e){}
})();
window.addEventListener("hashchange", ()=>{ if (!S.session) return; if (location.hash==="#inventory") go("inventory"); if (location.hash==="#schedule") go("schedule"); if (location.hash==="#events") go("events"); if (location.hash==="#cash") go("cash"); if (location.hash==="#dailycash"){ go("cash"); scrollToDailyCash(); } if (location.hash==="#alerts"){ go("overview"); scrollToAlerts(); } });
