/* JT Brewski's staff app · The Shifts tab: the schedule, coverage requests and the calendar link. */
"use strict";

/* ---------- Schedule ---------- */
const ymd = d => d.getFullYear()+"-"+pad(d.getMonth()+1)+"-"+pad(d.getDate());
const localDay = iso => ymd(new Date(iso));
function mondayOf(str){ const d = parseDay(str); d.setDate(d.getDate() - ((d.getDay()+6)%7)); return ymd(d); }
const tFmt = iso => new Date(iso).toLocaleTimeString([], {hour:"numeric", minute:"2-digit"});
const shiftEndDate = s => s.end_at ? new Date(s.end_at) : (()=>{ const d = new Date(s.start_at); if (d.getHours() >= 5) d.setDate(d.getDate()+1); d.setHours(2,0,0,0); return d; })();
const shiftRange = s => tFmt(s.start_at) + " – " + (s.end_at ? tFmt(s.end_at) : "Close");
const shiftDayLabel2 = iso => new Date(iso).toLocaleDateString([], {weekday:"short", month:"short", day:"numeric"});
const roleOfShift = s => roleById(s.role_id);
const whoOf = s => s.staff_id ? (s.staff_id===me().id ? "You" : staffName(s.staff_id)) : "Open shift";
function myShifts(){ return D().shifts.filter(s=>s.staff_id===me().id); }
function overlapsMine(s){
  const a = new Date(s.start_at), b = shiftEndDate(s);
  return myShifts().some(x=>x.id!==s.id && new Date(x.start_at) < b && shiftEndDate(x) > a);
}
function takeBlocker(s, strict){
  const m = me();
  if (!s.up_for_grabs || s.staff_id===m.id) return "gone";
  if (new Date(s.start_at) <= new Date()) return "started";
  if (s.role_id && !(m.roles||[]).includes(s.role_id) && (strict || !m.manager)) return "role";
  if (overlapsMine(s)) return "overlap";
  return null;
}
/* for the tab dot and the home strip: only shifts in your own roles, so managers aren't nagged by every open shift they post */
const forYouShifts = () => (S.data ? D().shifts.filter(s=>!takeBlocker(s, true)) : []);
/* which shifts to show for a week: from the app's data when it covers that week, otherwise ask the server */
function shiftsForWeek(ws){
  const we = ymd(new Date(parseDay(ws).getTime() + 6*86400e3));
  const lo = ymd(new Date(parseDay(shiftDay()).getTime() - 8*86400e3)), hi = ymd(new Date(parseDay(shiftDay()).getTime() + 43*86400e3));
  if (ws >= lo && we <= hi) return D().shifts.filter(s=>{ const d = localDay(s.start_at); return d >= ws && d <= we; });
  if (S.weekCache[ws]) return S.weekCache[ws];
  if (!S.weekCache["loading:"+ws]){
    S.weekCache["loading:"+ws] = true;
    call("api_schedule",{p_from:ws, p_to:we}).then(r=>{ S.weekCache[ws] = r || []; render(); }).catch(()=>{ S.weekCache[ws] = []; render(); });
  }
  return null;
}
function shiftRow(s){
  const r = roleOfShift(s), mine = s.staff_id===me().id, canTake = !takeBlocker(s);
  return h("button",{type:"button", class:"srow"+(mine?" is-mine":"")+(s.up_for_grabs?" grabs":"")+(new Date(s.start_at) < new Date() && shiftEndDate(s) < new Date() ? " past" : ""), onclick:()=>openShiftSheet(s)},
    h("span",{class:"stime"}, h("b",{text:tFmt(s.start_at)}), h("span",{text: s.end_at ? tFmt(s.end_at) : "Close"})),
    h("span",{class:"swho"},
      h("span",{class:"sname", text:whoOf(s)}),
      h("span",{class:"smeta"},
        r ? h("span",{class:"tag "+r.section, text:r.name}) : null,
        s.up_for_grabs ? h("span",{class:"tag "+(canTake||mine?"warn":"plain"), text:"Needs coverage"}) : null,
        s.note ? h("span",{class:"hint", text:s.note}) : null)));
}
/* turn on coverage alerts: check this phone once, quietly, the first time the Shifts tab opens */
function coverAlertsOn(){ return !!(S.push.sub && S.push.prefs && S.push.prefs.coverage); }
function checkPushOnce(){
  if (S.push.loaded || S.push.checking) return;
  S.push.checking = true; loadPush().finally(()=>{ S.push.checking = false; });
}
function coverCard(s){
  const m = me(), r = roleOfShift(s), mine = s.staff_id===m.id, blocker = takeBlocker(s), ck = "take:"+s.id, rk = "rm:"+s.id;
  const who = mine ? "You asked for coverage" : s.staff_id ? staffName(s.staff_id)+" needs someone" : "Open shift, nobody's on it yet";
  let action;
  if (mine) action = h("div",{class:"stack", style:"gap:8px"},
    h("p",{class:"hint", text:"It's still your shift until someone covers it."}),
    h("div",{class:"inline"},
      h("button",{type:"button", class:"btn ghost small", onclick:()=>act("api_unpost_shift",{p_id:s.id},"Got it. You're working it.")},"I'll work it"),
      s.created_by===m.id ? (S.confirm===rk
          ? h("button",{type:"button", class:"btn ghost small", onclick:()=>{ S.confirm=null; act("api_delete_shift",{p_id:s.id},"Request removed"); }},"Tap again to remove")
          : h("button",{type:"button", class:"linkbtn", onclick:()=>askConfirm(rk)},"Remove request")) : null));
  else if (!blocker) action = S.confirm===ck
    ? h("button",{type:"button", class:"btn", "data-own-sound":"", onclick:()=>takeShift(s)},"Tap again to cover it")
    : h("button",{type:"button", class:"btn ghost", onclick:()=>askConfirm(ck)},"I'll cover it");
  else action = h("p",{class:"hint cantcover", text: blocker==="role" ? "Needs a "+(r ? r.name.toLowerCase() : "different role")+"." : blocker==="overlap" ? "You're working then." : ""});
  return h("div",{class:"card covercard"+(mine?" mine-req":"")+(!blocker&&!mine?" can":"")},
    h("div",{class:"covtop"},
      h("div",{class:"covwhen"}, h("b",{text:shiftDayLabel2(s.start_at)}), h("span",{text:shiftRange(s)})),
      r ? h("span",{class:"tag "+r.section, text:r.name}) : null),
    h("p",{class:"covwho"}, h("b",{text:who}), s.posted_note ? h("span",{class:"hint", text:" “"+s.posted_note+"”"}) : null),
    action);
}
function coveredRow(c){
  const m = me(), r = roleById(c.role_id);
  const to = c.to_staff===m.id ? "You're" : c.to_name+" is";
  const from = c.from_staff===m.id ? "you" : c.from_staff ? c.from_name : "an open shift";
  return h("div",{class:"covrow"+(c.to_staff===m.id||c.from_staff===m.id?" me":"")},
    h("span",{class:"covicon", "aria-hidden":"true"},"✓"),
    h("span",{class:"t"},
      h("b",{text:to+" covering "+from}),
      h("span",{class:"hint", text:shiftDayLabel2(c.start_at)+" · "+shiftRange(c)+(r ? " · "+r.name : "")})));
}
function viewSchedule(){
  const admin = isAdmin(), out = [], now = new Date();
  const thisWeek = mondayOf(shiftDay());
  if (!S.week) S.week = thisWeek;
  const ws = S.week, wsd = parseDay(ws), wed = new Date(wsd.getTime() + 6*86400e3);
  const fmtD = d => d.toLocaleDateString([], {month:"short", day:"numeric"});
  const shifts = shiftsForWeek(ws);
  const step = n => { const d = parseDay(S.week); d.setDate(d.getDate()+7*n); S.week = ymd(d); render(); };
  checkPushOnce();

  /* coverage first */
  const open = D().shifts.filter(s=>s.up_for_grabs && new Date(s.start_at) > now).sort((a,b)=>a.start_at.localeCompare(b.start_at));
  const canDo = open.filter(s=>!takeBlocker(s)).length;
  out.push(h("div",{class:"rolehead"}, h("h2",{class:"ptitle", text:"Shifts"})));
  out.push(h("div",{class:"card coverhero"},
    h("div",{class:"eyebrow", text:"Shift coverage"}),
    h("h3",{text:"Can't make a shift?"}),
    h("p",{class:"hint", text:"Ask for coverage and everyone who can work it hears about it right away. It stays your shift until someone covers it."}),
    h("button",{type:"button", class:"btn", onclick:openCoverForm},"Ask for coverage"),
    S.push.loaded && !coverAlertsOn() ? h("button",{type:"button", class:"linkbtn alertlink", onclick:openNotify},"🔔 Get coverage alerts on this phone") : null));

  out.push(h("section",{class:"stack"},
    h("div",{class:"sec-head", style:"margin:0"}, h("h2",{text:"Needs coverage"}),
      open.length ? h("span",{class:"tag warn", text:open.length+(open.length===1?" shift":" shifts")}) : null),
    open.length ? open.map(coverCard)
                : h("div",{class:"card allcovered"}, h("span",{class:"covicon", "aria-hidden":"true"},"✓"), h("span",{text:"Every shift is covered right now."})),
    open.some(s=>s.staff_id!==me().id) && !canDo && !admin ? h("p",{class:"hint", text:"Nothing here you can pick up. You'll get an alert when a shift you can work needs someone."}) : null));

  const covers = (D().covers||[]).filter(c=>new Date(c.start_at) > new Date(now.getTime() - 12*3600e3)).slice(0, 12);
  if (covers.length) out.push(h("section",{class:"stack"},
    h("div",{class:"sec-head", style:"margin:0"}, h("h2",{text:"Covered"})),
    h("div",{class:"covlist"}, covers.map(coveredRow))));

  /* the full schedule */
  out.push(h("div",{class:"stack schedhead"},
    h("div",{class:"sec-head", style:"margin:0"}, h("h2",{text:"Full schedule"}),
      admin ? h("button",{type:"button", class:"btn small", onclick:()=>openShiftForm(null, ws===thisWeek ? shiftDay() : ws)},"Add shift") : null),
    h("div",{class:"weeknav"},
      h("button",{type:"button", class:"btn ghost small", "aria-label":"Previous week", onclick:()=>step(-1)},"‹"),
      h("div",{class:"weeklabel"}, h("b",{text:fmtD(wsd)+" – "+fmtD(wed)}), h("span",{class:"hint", text: ws===thisWeek ? "This week" : ws > thisWeek ? "Upcoming" : "Past week"})),
      h("button",{type:"button", class:"btn ghost small", "aria-label":"Next week", onclick:()=>step(1)},"›")),
    ws!==thisWeek ? h("button",{type:"button", class:"back", onclick:()=>{ S.week = thisWeek; render(); }},"← Back to this week") : null));

  /* the week */
  if (shifts==null) out.push(...skeleton("week"));
  else {
    const days = h("section",{class:"days"});
    for (let i=0;i<7;i++){
      const d = new Date(wsd.getTime() + i*86400e3), key = ymd(d);
      const list = shifts.filter(s=>localDay(s.start_at)===key).sort((a,b)=>a.start_at.localeCompare(b.start_at));
      days.append(h("div",{class:"day"+(key===shiftDay()?" today":"")},
        h("div",{class:"dayhead"},
          h("b",{text:d.toLocaleDateString([], {weekday:"long"})}),
          h("span",{class:"hint", text:fmtD(d)}),
          key===shiftDay() ? h("span",{class:"tag ok", text:"Today"}) : null,
          admin ? h("button",{type:"button", class:"linkbtn dayadd", "aria-label":"Add a shift on "+d.toLocaleDateString([], {weekday:"long"}), onclick:()=>openShiftForm(null, key)},"+ Add") : null),
        list.length ? h("div",{class:"slist"}, list.map(shiftRow)) : h("p",{class:"hint noshift", text:"No shifts"})));
    }
    out.push(days);
    if (admin){
      const prev = ymd(new Date(wsd.getTime() - 7*86400e3)), ck = "copy:"+ws;
      out.push(h("div",{class:"inline"},
        S.confirm===ck ? h("button",{type:"button", class:"btn small", onclick:async ()=>{ S.confirm=null;
            try { const n = await call("api_copy_week",{p_from:prev, p_to:ws}); toast(n ? "Copied "+n+(n===1?" shift":" shifts")+" from last week" : "Nothing new to copy from last week"); await refresh(); } catch(e){ toast(errMsg(e)); } }},"Tap again: copy last week into this one")
                       : h("button",{type:"button", class:"btn ghost small", onclick:()=>askConfirm(ck)},"Copy last week")));
    }
  }

  /* calendar */
  out.push(h("div",{class:"card calcard"},
    h("div",{class:"row"}, h("h3",{text:"Put your shifts in your calendar"})),
    h("p",{class:"hint", text:"Your shifts show up in Google or Apple Calendar on their own, and update when the schedule changes or you swap."}),
    h("button",{type:"button", class:"btn ghost", onclick:openCalendarSheet},"Add to my calendar")));
  return out;
}
async function takeShift(s){
  S.confirm = null;
  const who = s.staff_id ? staffName(s.staff_id)+"'s shift" : "the open shift";
  if (await act("api_take_shift",{p_id:s.id}, "Thanks! You're covering "+who+": "+shiftDayLabel2(s.start_at)+", "+shiftRange(s))) play("ok");
}
function openShiftSheet(s){
  const m = me(), r = roleOfShift(s), mine = s.staff_id===m.id, future = new Date(s.start_at) > new Date(), blocker = takeBlocker(s);
  const noteIn = h("input",{type:"text", id:"giveNote", maxlength:"120", placeholder:"e.g. family thing"});
  const kids = [
    h("h2",{text:shiftDayLabel2(s.start_at)}),
    h("div",{class:"bigtime", text:shiftRange(s)}),
    h("p",{class:"hint", text:[whoOf(s), r && r.name, s.end_at ? null : "until close (2 AM)"].filter(Boolean).join(" · ")}),
    s.note ? h("p",{text:s.note}) : null,
    s.up_for_grabs ? h("p",{}, h("span",{class:"tag warn", text:"Needs coverage"}), s.posted_note ? h("span",{class:"hint", text:"  “"+s.posted_note+"”"}) : null) : null];
  if (mine && future && !s.up_for_grabs) kids.push(
    h("label",{class:"lbl", for:"giveNote"}, "Can't make it? Add a note for your coworkers (optional)", noteIn),
    h("button",{type:"button", class:"btn", onclick:async ()=>{ closeSheet(); await act("api_post_shift",{p_id:s.id, p_note:noteIn.value}, "Asked for coverage. Your coworkers have been told."); }},"Ask for coverage"));
  if (mine && s.up_for_grabs) kids.push(h("p",{class:"hint", text:"You asked for coverage. It stays your shift until someone covers it."}),
    h("button",{type:"button", class:"btn ghost", onclick:()=>{ closeSheet(); act("api_unpost_shift",{p_id:s.id},"Got it. You're working it."); }},"I'll work it"));
  if (s.up_for_grabs && !mine){
    if (!blocker) kids.push(h("button",{type:"button", class:"btn", "data-own-sound":"", onclick:()=>{ closeSheet(); takeShift(s); }},"I'll cover it"));
    else if (blocker==="role") kids.push(h("p",{class:"hint", text:"Only people with the "+(r ? r.name : "right")+" role can cover this shift."}));
    else if (blocker==="overlap") kids.push(h("p",{class:"hint", text:"You're already working during this shift."}));
  }
  if (isAdmin()){
    kids.push(h("div",{class:"inline"},
      h("button",{type:"button", class:"btn ghost small", onclick:()=>{ closeSheet(); openShiftForm(s); }},"Edit shift"),
      !mine && s.staff_id && future && !s.up_for_grabs ? h("button",{type:"button", class:"btn ghost small", onclick:()=>{ closeSheet(); act("api_post_shift",{p_id:s.id, p_note:""}, "Asked for coverage on "+staffName(s.staff_id)+"'s shift"); }},"Ask for coverage") : null,
      h("button",{type:"button", class:"linkbtn warn", id:"delShiftBtn", onclick:e=>{
        if (e.target.dataset.armed){ closeSheet(); act("api_delete_shift",{p_id:s.id},"Shift deleted"); }
        else { e.target.dataset.armed = "1"; e.target.textContent = "Tap again to delete"; } }},"Delete shift")));
  }
  kids.push(h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Close"));
  openSheet(...kids);
}
/* anyone: ask for coverage on a shift on the schedule, or one that isn't on it yet */
function openCoverForm(){
  const m = me(), now = new Date();
  const mine = myShifts().filter(s=>new Date(s.start_at) > now && !s.up_for_grabs).sort((a,b)=>a.start_at.localeCompare(b.start_at)).slice(0, 6);
  const roles = (m.manager ? sortedRoles() : (m.roles||[]).map(roleById).filter(Boolean)).filter(r=>r.section!=="mgmt");
  let pick = mine.length ? mine[0].id : "new";
  const tomorrow = ymd(new Date(parseDay(shiftDay()).getTime() + 86400e3));
  const role = h("select",{id:"cfRole"}, roles.map(r=>h("option",{value:r.id}, r.name)));
  const date = h("input",{type:"date", id:"cfDate", value:tomorrow, min:ymd(now)});
  const st = h("input",{type:"time", id:"cfStart", value:"17:00"});
  const closeBox = h("input",{type:"checkbox", id:"cfClose", checked:true});
  const en = h("input",{type:"time", id:"cfEnd", value:"23:00", disabled:true});
  closeBox.addEventListener("change", ()=>{ en.disabled = closeBox.checked; });
  const fields = h("div",{class:"stack covfields"},
    roles.length > 1 ? h("label",{class:"lbl", for:"cfRole"}, "Role", role) : null,
    h("label",{class:"lbl", for:"cfDate"}, "Date", date),
    h("div",{class:"inline"}, h("label",{class:"lbl", for:"cfStart", style:"flex:1"}, "Starts", st), h("label",{class:"lbl", for:"cfEnd", style:"flex:1"}, "Ends", en)),
    h("label",{class:"toggle", for:"cfClose"}, closeBox, "Until close (2 AM)"));
  const choice = (val, title, sub) => h("label",{class:"choice"},
    h("input",{type:"radio", name:"cfPick", value:val, checked:pick===val, onchange:()=>{ pick = val; fields.hidden = pick!=="new"; }}),
    h("span",{}, h("b",{text:title}), sub ? h("span",{class:"hint", text:sub}) : null));
  fields.hidden = pick!=="new";
  const note = h("input",{type:"text", id:"cfNote", maxlength:"120", placeholder:"e.g. family thing"});
  const err = h("p",{class:"loginerr", role:"alert"});
  openSheet(
    h("h2",{text:"Ask for coverage"}),
    mine.length ? h("fieldset",{class:"choices"}, h("legend",{class:"lbl", text:"Which shift?"}),
      mine.map(s=>{ const r = roleOfShift(s); return choice(s.id, shiftDayLabel2(s.start_at)+" · "+shiftRange(s), r ? r.name : ""); }),
      choice("new", "A shift that's not on the schedule", "")) : h("p",{class:"hint", text:"Which shift do you need covered?"}),
    fields,
    h("label",{class:"lbl", for:"cfNote"}, "Note for your coworkers (optional)", note),
    h("p",{class:"hint", text:"Everyone who can work it gets a notification. It stays your shift until someone covers it."}),
    err,
    h("button",{type:"button", class:"btn", onclick:async e=>{
      e.target.disabled = true; err.textContent = "";
      try {
        if (pick!=="new") await call("api_post_shift",{p_id:pick, p_note:note.value});
        else {
          if (!date.value || !st.value){ err.textContent = "Pick a date and start time."; e.target.disabled = false; return; }
          await call("api_request_cover",{p_role_id: role.value || null, p_date:date.value, p_start:st.value, p_end: closeBox.checked ? null : en.value, p_note:note.value});
        }
        closeSheet(); toast("Asked for coverage. Your coworkers have been told."); play("ok"); await refresh();
      } catch(x){ err.textContent = errMsg(x); e.target.disabled = false; }
    }},"Ask for coverage"),
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Cancel"));
}
function openShiftForm(s, dateStr){
  const d = D(), staffSorted = d.staff.slice().sort((a,b)=>a.name.localeCompare(b.name));
  const start = s ? new Date(s.start_at) : null;
  const toHM = dt => pad(dt.getHours())+":"+pad(dt.getMinutes());
  const firstRole = st => (st && (st.roles||[]).map(roleById).find(r=>r && r.section!=="mgmt")) || null;
  const who = h("select",{id:"sfWho"},
    h("option",{value:"", selected:s && !s.staff_id},"Open shift (anyone with the role can take it)"),
    staffSorted.map(p=>h("option",{value:p.id, selected:s && s.staff_id===p.id}, p.name)));
  const role = h("select",{id:"sfRole"},
    h("option",{value:""},"No role"),
    sortedRoles().map(r=>h("option",{value:r.id, selected:s ? s.role_id===r.id : false}, r.name+" ("+secInfo(r.section)[2]+")")));
  const date = h("input",{type:"date", id:"sfDate", value: s ? localDay(s.start_at) : (dateStr || shiftDay())});
  const st = h("input",{type:"time", id:"sfStart", value: s ? toHM(start) : "17:00"});
  const closeBox = h("input",{type:"checkbox", id:"sfClose", checked: s ? !s.end_at : true});
  const en = h("input",{type:"time", id:"sfEnd", value: s && s.end_at ? toHM(new Date(s.end_at)) : "23:00", disabled: s ? !s.end_at : true});
  closeBox.addEventListener("change", ()=>{ en.disabled = closeBox.checked; });
  const note = h("input",{type:"text", id:"sfNote", maxlength:"120", value: s ? s.note : "", placeholder:"Optional, e.g. trivia night"});
  who.addEventListener("change", ()=>{ if (!role.value){ const r = firstRole(d.staff.find(p=>p.id===who.value)); if (r) role.value = r.id; } });
  const err = h("p",{class:"loginerr", role:"alert"});
  openSheet(
    h("h2",{text: s ? "Edit shift" : "Add shift"}),
    h("label",{class:"lbl", for:"sfWho"}, "Who", who),
    h("label",{class:"lbl", for:"sfRole"}, "Role", role),
    h("label",{class:"lbl", for:"sfDate"}, "Date", date),
    h("div",{class:"inline"}, h("label",{class:"lbl", for:"sfStart", style:"flex:1"}, "Starts", st), h("label",{class:"lbl", for:"sfEnd", style:"flex:1"}, "Ends", en)),
    h("label",{class:"toggle", for:"sfClose"}, closeBox, "Until close (2 AM)"),
    h("label",{class:"lbl", for:"sfNote"}, "Note", note),
    err,
    h("button",{type:"button", class:"btn", onclick:async e=>{
      if (!date.value || !st.value){ err.textContent = "Pick a date and start time."; return; }
      e.target.disabled = true;
      try {
        await call("api_save_shift",{p_id: s ? s.id : null, p_staff_id: who.value || null, p_role_id: role.value || null,
          p_date: date.value, p_start: st.value, p_end: closeBox.checked ? null : en.value, p_note: note.value});
        closeSheet(); toast(s ? "Shift updated" : "Shift added");
        S.week = mondayOf(date.value); await refresh();
      } catch(x){ err.textContent = errMsg(x); e.target.disabled = false; }
    }}, s ? "Save shift" : "Add shift"),
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Cancel"));
  if (!s && !role.value){ const r = firstRole(d.staff.find(p=>p.id===who.value)); if (r) role.value = r.id; }
}
async function openCalendarSheet(){
  let link;
  try { link = await call("api_cal_link"); } catch(e){ return toast(errMsg(e)); }
  let team = false;
  const box = h("div",{class:"stack"});
  const draw = () => {
    const url = CFG.supabaseUrl.replace(/\/$/,"") + "/functions/v1/calendar?t=" + link.token + (team ? "&all=1" : "");
    const webcal = url.replace(/^https?:/, "webcal:");
    box.replaceChildren(...[
      link.manager ? h("div",{class:"chips", role:"group", "aria-label":"Which calendar"},
        h("button",{type:"button", class:"chip", "aria-pressed":String(!team), onclick:()=>{ team = false; draw(); }},"My shifts"),
        h("button",{type:"button", class:"chip", "aria-pressed":String(team), onclick:()=>{ team = true; draw(); }},"Whole team")) : null,
      h("a",{class:"btn", href:"https://calendar.google.com/calendar/render?cid="+encodeURIComponent(webcal), target:"_blank", rel:"noopener"},"Add to Google Calendar"),
      h("a",{class:"btn ghost", href:webcal},"Add to Apple Calendar"),
      h("button",{type:"button", class:"btn ghost", onclick:async ()=>{ try { await navigator.clipboard.writeText(url); toast("Calendar link copied"); } catch(e){ toast("Press and hold the link below to copy it"); } }},"Copy link"),
      h("div",{class:"boardlink", text:url})].filter(Boolean));
  };
  draw();
  openSheet(
    h("h2",{text:"Add to your calendar"}),
    h("p",{class:"hint", text:"Subscribe once and your shifts appear in your calendar app by themselves. Google Calendar checks for changes every few hours, so a swap can take a while to show there. The app always has the latest."}),
    box,
    h("p",{class:"hint", text:"This link is private to you. If it ever gets shared, reset it here and add your calendar again."}),
    h("button",{type:"button", class:"linkbtn", onclick:async e=>{
      if (!e.target.dataset.armed){ e.target.dataset.armed = "1"; e.target.textContent = "Tap again to reset your calendar link"; return; }
      try { link = await call("api_cal_reset"); draw(); toast("New link made. The old one stopped working."); e.target.textContent = "Reset my link"; delete e.target.dataset.armed; } catch(x){ toast(errMsg(x)); } }},"Reset my link"),
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Close"));
}
