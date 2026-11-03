/* JT Brewski's staff app · Notify a manager: staff alerts and handling them. */
"use strict";

/* ---------- notify a manager ----------
   Anyone can send the managers a heads-up: front or back of house, and optionally one manager by name.
   Managers see open alerts at the top of the Tasks tab and mark them handled; the sender sees when it's handled. */
const staffAlerts = () => D().alerts || [];
const openAlerts = () => staffAlerts().filter(a=>!a.handled_at);
const AREAS = {foh:["Front of house","Bar, floor, guests"], boh:["Back of house","Kitchen, dish, walk-in"]};
function scrollToAlerts(){ requestAnimationFrame(()=>{ const el = $("staffAlerts"); if (el) el.scrollIntoView({block:"center", behavior:"smooth"}); }); }
function alertsBoardRow(){
  if (!isAdmin()) return null;
  const open = openAlerts(); if (!open.length) return null;
  const mine = open.filter(a=>a.to_staff===me().id).length;
  return boardRow("tn-alert", open.length===1 ? "Alert from "+open[0].from_name.split(/\s+/)[0] : open.length+" staff alerts",
    mine ? "For you" : "See it", ()=>{ go("overview"); scrollToAlerts(); }, true);
}
function alertRow(a, forMgr){
  const area = AREAS[a.area] || ["",""];
  return h("div",{class:"alertrow"+(a.handled_at ? " done" : "")},
    h("div",{class:"line"},
      h("span",{class:"tag "+a.area, text:a.area==="foh" ? "FOH" : "BOH"}),
      forMgr && a.to_staff===me().id ? h("span",{class:"tag warn", text:"For you"}) : null,
      h("span",{class:"hint", text: forMgr ? a.from_name+" · "+when(a.at)+(a.to_name && a.to_staff!==me().id ? " · for "+a.to_name : "")
                                           : "To "+(a.to_name || "any manager")+" · "+when(a.at)})),
    h("p",{class:"alerttext", text:a.text}),
    forMgr ? (canWrite() && !a.handled_at ? h("button",{type:"button", class:"btn small", onclick:()=>act("api_handle_alert",{p_id:a.id, p_done:true}, "Marked handled")}, "Handled") : null)
           : h("span",{class:"tag "+(a.handled_at ? "ok" : "plain"), text: a.handled_at ? "Handled by "+(a.handled_by_name||"a manager") : "Waiting for a manager"}));
}
function alertsSection(){
  const admin = isAdmin(), out = [];
  if (admin){
    const open = openAlerts().sort((a,b)=>Number(b.to_staff===me().id)-Number(a.to_staff===me().id) || String(a.at).localeCompare(String(b.at)));
    if (open.length) out.push(h("section",{class:"card stack alertcard", id:"staffAlerts"},
      h("div",{class:"row"}, h("h2",{text:"Alerts from staff"}), h("span",{class:"tag warn", text:String(open.length)})),
      open.map(a=>alertRow(a, true))));
  }
  out.push(h("button",{type:"button", class:"btn ghost notifybtn", disabled:!canWrite(), onclick:openNotifyManager}, icon("hand"), h("span",{text:"Notify a manager"})));
  if (!admin){
    const mine = staffAlerts().filter(a=>a.from_id===me().id).slice(0, 3);
    if (mine.length) out.push(h("div",{class:"stack myalerts", id:"staffAlerts"}, mine.map(a=>alertRow(a, false))));
  }
  return out;
}
function openNotifyManager(){
  const m = me(), secs = new Set((m.roles||[]).map(id=>(roleById(id)||{}).section));
  let area = secs.has("foh") && !secs.has("boh") ? "foh" : secs.has("boh") && !secs.has("foh") ? "boh" : null;
  const mgrs = D().staff.filter(s=>isManagerStaff(s) && s.has_login && s.id!==m.id).sort((a,b)=>a.name.localeCompare(b.name));
  const who = h("select",{id:"nmWho"}, h("option",{value:""},"Any manager"), mgrs.map(s=>h("option",{value:s.id}, s.name)));
  const text = h("textarea",{id:"nmText", rows:"3", maxlength:"600", placeholder:"e.g. The walk-in is reading 45°, or a guest is asking for a manager"});
  const err = h("p",{class:"loginerr", role:"alert"});
  const pick = val => h("label",{class:"yn"}, h("input",{type:"radio", name:"nmArea", value:val, checked:area===val, onchange:()=>{ area = val; err.textContent = ""; }}),
    h("span",{}, h("b",{text:AREAS[val][0]}), h("small",{text:AREAS[val][1]})));
  openSheet(
    h("h2",{text:"Notify a manager"}),
    h("p",{class:"hint", style:"margin:-4px 0 0", text:"For anything a manager should know about. Can’t make a shift? Use Ask for coverage on the Shifts tab instead."}),
    h("fieldset",{class:"choices"}, h("legend",{class:"lbl", text:"What’s it about?"}), h("div",{class:"ynpick"}, pick("foh"), pick("boh"))),
    h("label",{class:"lbl", for:"nmWho"}, "Which manager? (optional)", who),
    h("label",{class:"lbl", for:"nmText"}, "What’s going on?", text),
    err,
    h("button",{type:"button", class:"btn", onclick:async ev=>{
      if (!area){ err.textContent = "Pick front of house or back of house."; return; }
      if (!text.value.trim()){ err.textContent = "Say what’s going on."; text.focus(); return; }
      ev.target.disabled = true; err.textContent = "";
      try {
        await call("api_notify_manager",{p_area:area, p_to:who.value||null, p_text:text.value});
        play("ok"); closeSheet(); toast(who.value ? "Sent to "+staffName(who.value) : "Sent to the managers"); await refresh();
      } catch(x){ if (x.code==="not_logged_in") return logOut("You've been logged out. Enter your number again."); err.textContent = errMsg(x); ev.target.disabled = false; }
    }}, "Send alert"),
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Cancel"));
}
