/* JT Brewski's staff app · Actions, inviting people, logging in, Settings and notifications. */
"use strict";

/* ---------- actions ---------- */
async function toggleTask(t){
  if (!canWrite()) return toast(errMsg({code:"offline"}));
  const before = {done:t.done, done_day:t.done_day, done_until:t.done_until, done_by:t.done_by, done_by_name:t.done_by_name, done_at:t.done_at};
  if (isDone(t)) Object.assign(t, {done:false, done_day:null, done_until:null, done_by:null, done_by_name:null, done_at:null});
  else Object.assign(t, {done:true, done_day:shiftDay(), done_until:RECURRING.has(t.repeat) ? new Date(Date.now()+3600e3).toISOString() : null,
                         done_by:me().id, done_by_name:me().name, done_at:new Date().toISOString()});
  S.fx.task = t.id;
  if (!isDone(t)) play("undo");
  else { const rp = progressOf(visibleTasks().filter(countsToday)); play(rp.total && rp.done===rp.total ? "cheers" : "clink"); }
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
/* ---------- inviting people ---------- */
const APP_URL = new URL("./", location.href).href;
const POSTER_URL = new URL("poster.html", location.href).href;
function inviteText(name, pin){
  return "Hi "+(name||"").trim().split(/\s+/)[0]+"! Here’s the JT Brewski’s staff app: "+APP_URL+"\n\n"+
    (pin ? "Your login number is "+pin+". Keep it to yourself.\n\n" : "Ask a manager for your login number.\n\n")+
    "iPhone: open the link in Safari, tap Share, then Add to Home Screen, and open it from your home screen.\n"+
    "Android: open it in Chrome and tap Install app.\n\nThen turn on notifications in Settings.";
}
/* the phone's share sheet (Messages, WhatsApp…), else a text message, else copy */
async function shareInvite(name, pin){
  const text = inviteText(name, pin);
  if (navigator.share){ try { await navigator.share({text}); return; } catch(e){ if (e && e.name==="AbortError") return; } }
  location.href = "sms:?&body="+encodeURIComponent(text);
}
async function copyInvite(name, pin){
  try { await navigator.clipboard.writeText(inviteText(name, pin)); toast("Copied. Paste it in a text to "+name.split(/\s+/)[0]+"."); }
  catch(e){ toast("Couldn't copy on this phone. Use Text it instead."); }
}
function showNumber(name, pin){
  openSheet(h("h2",{text:name+"'s login number"}), h("div",{class:"bignum", text:pin}),
    h("p",{class:"hint", text:"The number isn't shown again. Send it to "+name.split(/\s+/)[0]+" now with the link to the app and how to set it up. If it's forgotten, assign a new one."}),
    h("button",{type:"button", class:"btn", onclick:()=>shareInvite(name, pin)}, "Text it to "+name.split(/\s+/)[0]),
    h("button",{type:"button", class:"btn ghost", onclick:()=>copyInvite(name, pin)}, "Copy the message"),
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Done"));
}
function openInviteSheet(){
  openSheet(h("h2",{text:"Get the team on the app"}),
    h("p",{class:"hint", style:"margin:0", text:"Everyone needs a login number first: assign one below, and you can text it to them with the link right away."}),
    h("button",{type:"button", class:"btn", onclick:()=>shareInvite("there", null)},"Share the app link"),
    h("a",{class:"btn ghost", href:POSTER_URL, target:"_blank", rel:"noopener", style:"text-align:center;text-decoration:none"},"Open the sign-up poster"),
    h("p",{class:"hint", style:"margin:0", text:"The poster has a QR code that opens the app, and the steps to add it to a phone. Print it and put it up behind the bar or in the kitchen."}),
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Close"));
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
/* ---------- settings ---------- */
const THEMES = [["auto","Automatic"],["light","Light"],["dark","Dark"]];
function themeNow(){ try { const t = localStorage.getItem("brewskis.theme"); return t==="light"||t==="dark" ? t : "auto"; } catch(e){ return "auto"; } }
function setTheme(t){
  try { if (t==="auto") localStorage.removeItem("brewskis.theme"); else localStorage.setItem("brewskis.theme", t); } catch(e){}
  if (t==="auto") document.documentElement.removeAttribute("data-theme"); else document.documentElement.setAttribute("data-theme", t);
  render();
}
function setRow(title, sub, value, onclick){
  return h("button",{type:"button", class:"setrow", onclick},
    h("span",{class:"t"}, h("b",{text:title}), sub ? h("span",{class:"hint", text:sub}) : null),
    value ? h("span",{class:"val", text:value}) : null,
    h("span",{class:"chev-r", "aria-hidden":"true", text:"›"}));
}
function viewSettings(){
  const m = me(), admin = isAdmin();
  checkPushOnce();
  const pushOn = !!(S.push.sub && S.push.prefs);
  const pushVal = !pushSupported() ? "Not available" : (typeof Notification!=="undefined" && Notification.permission==="denied") ? "Blocked" : !S.push.loaded ? "" : pushOn ? "On" : "Off";
  const theme = themeNow();
  const out = [h("div",{class:"rolehead"}, h("h2",{class:"ptitle", text:"Settings"}))];

  out.push(h("section",{class:"stack"},
    h("h3",{class:"sethead", text:"Account"}),
    h("div",{class:"card acct"},
      h("div",{class:"row", style:"justify-content:flex-start;gap:12px;flex-wrap:nowrap"},
        h("span",{class:"dot big-dot", "aria-hidden":"true", text:initials(m.name)}),
        h("span",{class:"t"}, h("b",{text:m.name}),
          h("span",{class:"hint", text:(m.roles||[]).map(roleName).filter(Boolean).join(", ") || "No roles yet"}))),
      h("p",{class:"hint", style:"margin:0", text:"This phone logs out by itself 16 hours after you log in."}),
      h("button",{type:"button", class:"btn ghost", onclick:()=>logOut()},"Log out"))));

  out.push(h("section",{class:"stack"},
    h("h3",{class:"sethead", text:"This phone"}),
    setRow("Notifications", admin ? "Coverage, new tasks, staff alerts, orders, overdue tasks, cash-outs, recap" : "Shift coverage and new tasks", pushVal, ()=>openNotify()),
    h("label",{class:"soundrow", for:"soundToggle"},
      h("span",{}, h("b",{text:"Sounds"}), h("span",{class:"hint", text:"A soft tap on every button, a clink when you check off a task, and ticks when you count."+(navigator.vibrate ? " Includes a short vibration." : "")})),
      h("input",{type:"checkbox", id:"soundToggle", class:"switch", role:"switch", checked:soundOn, onchange:e=>{ setSound(e.target.checked); render(); }})),
    h("div",{class:"card appear"},
      h("b",{id:"themeLbl", text:"Appearance"}),
      h("div",{class:"seg", role:"radiogroup", "aria-labelledby":"themeLbl"},
        THEMES.map(([id,label])=>h("button",{type:"button", role:"radio", "aria-checked":String(theme===id), onclick:()=>setTheme(id)}, label))),
      h("span",{class:"hint", text: theme==="auto" ? "Follows your phone's light or dark mode." : "Always "+theme+" on this phone."}))));

  if (admin) out.push(h("section",{class:"stack"},
    h("h3",{class:"sethead", text:"Managers"}),
    setRow("Team, roles & login numbers", "Add people, change roles, set login numbers", "", ()=>{ go("team"); loadVersions(); }),
    setRow("Party deposit", "The usual amount to lock in a party date", depositSetting()!=null ? money(depositSetting()) : "Not set", openDepositSetting)));

  out.push(h("section",{class:"stack"},
    h("h3",{class:"sethead", text:"App"}),
    h("div",{class:"card"}, versionLine(),
      updateReady() ? h("button",{type:"button", class:"btn", disabled:S.updating, onclick:applyUpdate}, S.updating ? "Updating…" : "Update now") : null),
    !isStandalone() ? installHelp() : null));
  return out;
}

/* ---------- manager notifications ---------- */
const pushSupported = () => "serviceWorker" in navigator && "PushManager" in window && "Notification" in window;
function b64uToBytes(str){ const pad = "=".repeat((4 - str.length % 4) % 4); const raw = atob((str + pad).replace(/-/g,"+").replace(/_/g,"/")); return Uint8Array.from(raw, c=>c.charCodeAt(0)); }
const functionsUrl = () => CFG.supabaseUrl.replace(/\/$/,"") + "/functions/v1/notify";
function openNotify(){ S.notifyBack = S.view==="notify" ? S.notifyBack : S.view; S.view = "notify"; S.push.err = ""; render(); window.scrollTo(0,0); loadPush(); }
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
  const mgr = isAdmin();
  const out = [h("div",{class:"rolehead"},
    h("button",{type:"button", class:"back", onclick:()=>go(S.notifyBack || "overview")},"← Back"),
    h("h2",{class:"ptitle", text:"Notifications"}),
    h("p",{class:"hint", text:"These settings are for this phone only. Everyone turns notifications on on their own phone."}))];
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
  if (!S.push.loaded){ out.push(...skeleton("rows")); return out; }
  if (S.push.err) out.push(h("p",{class:"loginerr", role:"alert", text:S.push.err}));
  if (!S.push.sub || !S.push.prefs){
    out.push(h("div",{class:"card"},
      h("h3",{text:"Get alerts on this phone"}),
      mgr ? h("ul",{class:"steps"},
        h("li",{text:"Shifts that need coverage, and when someone covers one"}),
        h("li",{text:"New tasks for you, your role, or everyone"}),
        h("li",{text:"Order deadlines coming up that haven't been ordered"}),
        h("li",{text:"Tasks that go overdue, and items counted at zero"}),
        h("li",{text:"A drawer that comes up short at close"}),
        h("li",{text:"Alerts from staff who tap Notify a manager"}),
        h("li",{text:"A recap of each shift day's tasks"}))
      : h("ul",{class:"steps"},
        h("li",{text:"Right away when a shift you can work needs coverage"}),
        h("li",{text:"When someone covers your shift"}),
        h("li",{text:"New tasks for you, your role, or everyone"})),
      h("button",{type:"button", class:"btn", disabled:S.push.busy, onclick:enablePush}, S.push.busy ? "Turning on…" : "Turn on notifications")));
    return out;
  }
  const p = S.push.prefs;
  const timeInput = (id, key) => h("input",{type:"time", id, value:p[key], disabled:S.push.busy, onchange:e=>{ if (e.target.value) updatePush({[key]:e.target.value}); }});
  const coverRows = [
    prefRow("coverage", "Shifts that need coverage", mgr ? "Every coverage request and open shift, right away." : "Right away, when a shift you can work needs someone."),
    prefRow("swaps", "Shifts covered", mgr ? "When someone covers a shift." : "When someone covers your shift, or one you were told about."),
    prefRow("tasks", "New tasks", mgr ? "When another manager adds a task for everyone, your role, or you." : "When a manager adds a task for you, your role, or everyone.")];
  if (!mgr) out.push(h("div",{class:"card prefs"}, ...coverRows,
    prefRow("quiet", "Quiet hours", "Alerts wait until quiet hours end.",
      h("div",{class:"inline"}, h("label",{class:"lbl", for:"pfQs"}, "From", timeInput("pfQs","quiet_start")), h("label",{class:"lbl", for:"pfQe"}, "To", timeInput("pfQe","quiet_end"))))));
  else out.push(h("div",{class:"card prefs"}, ...coverRows,
    prefRow("orders", "Order deadlines", "Before a supplier's cutoff, if that order hasn't been marked placed.",
      h("label",{class:"lbl", for:"pfLead"}, "Remind me",
        h("select",{id:"pfLead", disabled:S.push.busy, onchange:e=>updatePush({lead_hours:Number(e.target.value)})},
          [[1,"1 hour before"],[2,"2 hours before"],[4,"4 hours before"],[24,"1 day before"]].map(([v,l])=>h("option",{value:v, selected:Number(p.lead_hours)===v}, l))))),
    prefRow("overdue", "Overdue tasks", "When a task passes its due date or due time without being checked off. One alert per task."),
    prefRow("out", "Out of stock", "When someone counts an item at 0."),
    canCashBook() ? prefRow("cashbook", "Daily cash", "When one of the others enters a day’s cash numbers.") : null,
    prefRow("staff", "Alerts from staff", "When someone taps Notify a manager. One sent to you by name comes through even during quiet hours."),
    prefRow("cash", "Short drawers", "When a drawer comes up short at close."),
    prefRow("summary", "Nightly recap", "How many tasks got checked off in the shift day that just ended, what's overdue, and any drawer that came up short.",
      h("label",{class:"lbl", for:"pfRecap"}, "Send at", timeInput("pfRecap","summary_time"))),
    prefRow("quiet", "Quiet hours", "Alerts wait until quiet hours end. The recap still arrives at the time you picked.",
      h("div",{class:"inline"}, h("label",{class:"lbl", for:"pfQs"}, "From", timeInput("pfQs","quiet_start")), h("label",{class:"lbl", for:"pfQe"}, "To", timeInput("pfQe","quiet_end"))))));
  out.push(h("div",{class:"inline"},
    h("button",{type:"button", class:"btn", disabled:S.push.busy, onclick:testPush},"Send a test"),
    h("button",{type:"button", class:"btn ghost", disabled:S.push.busy, onclick:disablePush},"Turn off on this phone")));
  out.push(h("p",{class:"hint", text: mgr ? "Coverage and new-task alerts go out right away. Other alerts are checked every 15 minutes." : "Alerts go out right away."}));
  return out;
}
function installHelp(){
  if (S.installEvent) return h("button",{type:"button", class:"btn ghost", onclick:install},"Install the app on this device");
  if (isIOS()) return h("div",{class:"card"}, h("h3",{text:"Add it to your home screen"}),
    h("ol",{class:"steps"}, h("li",{text:"Open this page in Safari."}), h("li",{text:"Tap the Share button."}), h("li",{text:"Tap Add to Home Screen, then Add."})));
  return null;
}
async function install(){ const ev = S.installEvent; if (!ev) return; S.installEvent = null; $("installBtn").hidden = true; closeSheet(); ev.prompt(); try { await ev.userChoice; } catch(e){} }
