/* JT Brewski's staff app · The Events tab: the calendar, repeating events and promotion tasks. */
"use strict";

/* ---------- Events ---------- */
const EVENT_KINDS = [["party","Party","🎉"],["entertainment","Entertainment","🎤"],["standard","Standard","📅"],["other","Other","✦"]];
const kindInfo = k => EVENT_KINDS.find(x=>x[0]===k) || EVENT_KINDS[3];
const PROMO_LEADS = [[14,"2 weeks before"],[7,"1 week before"],[1,"Day before"]];
const eventById = id => (D().events||[]).find(e=>e.id===id);
const promoTasks = e => D().tasks.filter(t=>t.event_id===e.id).sort((a,b)=>(b.event_lead||0)-(a.event_lead||0));
function kindTag(k){ const [id,label,icon] = kindInfo(k); return h("span",{class:"tag ev-"+id}, icon+" "+label); }
function eventTime(e){
  if (!e.start_time) return e.end_time ? "Until "+fmtClock(e.end_time) : "";
  return fmtClock(e.start_time) + (e.end_time ? " – "+fmtClock(e.end_time) : "");
}
function eventWhen(e){
  const today = shiftDay(), diff = Math.round((parseDay(e.day) - parseDay(today))/86400e3);
  if (diff===0) return e.start_time && Number(hhmm(e.start_time).slice(0,2)) >= 16 ? "Tonight" : "Today";
  if (diff===1) return "Tomorrow";
  if (diff > 1 && diff < 7) return "This "+parseDay(e.day).toLocaleDateString(undefined,{weekday:"long"});
  if (diff >= 7 && diff < 14) return "Next "+parseDay(e.day).toLocaleDateString(undefined,{weekday:"long"});
  if (diff > 0) return "In "+diff+" days";
  return "";
}
const shortDay = str => parseDay(str).toLocaleDateString(undefined,{weekday:"short", month:"short", day:"numeric"});
const promoDue = str => { const f = fmtDue(str); return /^(today|tomorrow)$/.test(f) ? f : shortDay(str); };
const longDay = str => parseDay(str).toLocaleDateString(undefined,{weekday:"long", month:"long", day:"numeric"});

/* ---------- repeating events ----------
   An event's day is its first date. Repeating Standard events happen every week, every other week,
   monthly on the same date, monthly on the same weekday (2nd Tuesday) or the last one (last Friday),
   up to repeat_until, minus any skip_dates. */
const isRepeating = e => !!e.repeat && e.repeat!=="none";
const weekdayName = (str, style="long") => parseDay(str).toLocaleDateString(undefined,{weekday:style});
const nthOf = str => Math.ceil(parseDay(str).getDate()/7);
function inLastWeek(str){ const d = parseDay(str); return d.getDate() + 7 > new Date(d.getFullYear(), d.getMonth()+1, 0).getDate(); }
/* the choices for a first date, e.g. weekly = "Every Tuesday" */
function repeatOptions(str){
  const wd = weekdayName(str), n = nthOf(str), out = [["none","Doesn't repeat"]];
  if (!str) return out;
  out.push(["weekly","Every "+wd], ["biweekly","Every other "+wd], ["monthly","Monthly on the "+ordinal(parseDay(str).getDate())]);
  if (n <= 4) out.push(["monthly_nth","Monthly on the "+ordinal(n)+" "+wd]);
  if (inLastWeek(str)) out.push(["monthly_last","Monthly on the last "+wd]);
  return out;
}
function repeatText(e, short){
  const first = e.first || e.day, wd = weekdayName(first, short ? "short" : "long");
  return ({weekly:"Every "+wd, biweekly:"Every other "+wd, monthly:(short ? "Monthly · " : "Monthly on the ")+ordinal(parseDay(first).getDate()),
           monthly_nth:(short ? "" : "Monthly on the ")+ordinal(nthOf(first))+" "+wd+(short ? " monthly" : ""),
           monthly_last:(short ? "Last "+wd+" monthly" : "Monthly on the last "+wd)})[e.repeat] || "";
}
/* the dates an event happens between from and to (inclusive, YYYY-MM-DD) */
function eventDates(e, from, to){
  const start = e.day, end = e.repeat_until && e.repeat_until < to ? e.repeat_until : to;
  if (!isRepeating(e)) return start >= from && start <= to ? [start] : [];
  const lo = start > from ? start : from;
  if (lo > end) return [];
  const skip = new Set(e.skip_dates||[]), out = [];
  if (e.repeat==="weekly" || e.repeat==="biweekly"){
    const step = e.repeat==="weekly" ? 7 : 14;
    const behind = Math.round((parseDay(lo) - parseDay(start))/86400e3);
    for (let d = addDays(start, Math.ceil(behind/step)*step), i = 0; d <= end && i < 400; d = addDays(d, step), i++) if (!skip.has(d)) out.push(d);
    return out;
  }
  const s0 = parseDay(start), wd = s0.getDay(), n = nthOf(start);
  let y = parseDay(lo).getFullYear(), m = parseDay(lo).getMonth();
  for (let i=0; i<120; i++, m++){
    if (m > 11){ m = 0; y++; }
    if (ymd(new Date(y, m, 1)) > end) break;
    let dt = null;
    if (e.repeat==="monthly") dt = monthDay(y, m, s0.getDate());
    else if (e.repeat==="monthly_nth"){ const day = 1 + (wd - new Date(y, m, 1).getDay() + 7) % 7 + (n-1)*7; if (day <= new Date(y, m+1, 0).getDate()) dt = new Date(y, m, day); }
    else if (e.repeat==="monthly_last"){ const last = new Date(y, m+1, 0); dt = new Date(y, m, last.getDate() - (last.getDay() - wd + 7) % 7); }
    if (!dt) continue;
    const ds = ymd(dt);
    if (ds >= lo && ds <= end && !skip.has(ds)) out.push(ds);
  }
  return out;
}
/* one entry per date an event happens; `first` keeps the series' first date */
const instanceOf = (e, day) => Object.assign({}, e, {day, first:e.day});
function eventInstances(from, to){
  const out = [];
  for (const e of D().events||[]) for (const day of eventDates(e, from, to)) out.push(instanceOf(e, day));
  return out.sort((a,b)=>a.day.localeCompare(b.day) || hhmm(a.start_time).localeCompare(hhmm(b.start_time)) || a.title.localeCompare(b.title));
}
/* coming up: one-off events, plus each repeating event once, at its next date */
function upcomingEvents(){
  const today = shiftDay(), seen = new Set();
  return eventInstances(today, addDays(today, 400)).filter(x=>{ if (!isRepeating(x)) return true; if (seen.has(x.id)) return false; seen.add(x.id); return true; });
}

function viewEvents(){
  const admin = isAdmin(), out = [], today = shiftDay();
  if (!S.evMonth) S.evMonth = today.slice(0,7);
  const up = upcomingEvents();

  out.push(h("div",{class:"sec-head tasks-head"}, h("h2",{class:"ptitle", text:"Events"}),
    admin && canWrite() ? h("button",{type:"button", class:"btn small", onclick:()=>openEventForm(null, S.evDay && S.evDay >= today ? S.evDay : null)},"Add event") : null));

  if (admin) out.push(partiesCard());

  /* next up */
  const next = up[0];
  if (next) out.push(h("button",{type:"button", class:"evhero ev-"+next.kind, onclick:()=>openEventSheet(next)},
    h("span",{class:"eyebrow", text:"Next up · "+eventWhen(next)}),
    h("span",{class:"evtitle", text:next.title}),
    h("span",{class:"evwhen", text:[shortDay(next.day), eventTime(next)].filter(Boolean).join(" · ")}),
    h("span",{class:"line"}, kindTag(next.kind), isRepeating(next) ? h("span",{class:"tag", text:"↻ "+repeatText(next, true)}) : null,
      up.length > 1 ? h("span",{class:"more", text:"+"+(up.length-1)+" more coming up"}) : null)));
  else out.push(emptyCard("Nothing on the calendar", admin
    ? "Add parties, live music, trivia, game days and anything else coming up. Standard events can repeat, and any event can get promotion reminders for managers."
    : "When a manager adds an event, it shows up here."));

  out.push(calendarCard());

  /* upcoming list */
  if (up.length){
    let lastMonth = "";
    const rows = [];
    for (const e of up.slice(0, 40)){
      const m = e.day.slice(0,7);
      if (m!==lastMonth){ lastMonth = m; rows.push(h("div",{class:"divider", text:parseDay(e.day).toLocaleDateString(undefined,{month:"long", year: m.slice(0,4)===today.slice(0,4) ? undefined : "numeric"})})); }
      rows.push(eventRow(e));
    }
    out.push(h("section",{class:"stack"},
      h("div",{class:"sec-head", style:"margin:0"}, h("h2",{text:"Coming up"}), h("span",{class:"tag plain", text:up.length+(up.length===1?" event":" events")})),
      h("div",{class:"evlist"}, rows),
      up.some(isRepeating) ? h("p",{class:"hint", style:"margin:0", text:"Repeating events are listed once, at their next date. The calendar shows every date."}) : null));
  }
  return out;
}
function calendarCard(){
  const today = shiftDay(), [y,m] = S.evMonth.split("-").map(Number);
  const first = new Date(y, m-1, 1), start = new Date(y, m-1, 1 - first.getDay());
  const weeks = Math.ceil((first.getDay() + new Date(y, m, 0).getDate())/7);
  const byDay = {}; for (const x of eventInstances(ymd(start), addDays(ymd(start), weeks*7-1))) (byDay[x.day] = byDay[x.day] || []).push(x);
  const step = n => { const d = new Date(y, m-1+n, 1); S.evMonth = d.getFullYear()+"-"+pad(d.getMonth()+1); S.evDay = null; render(); };
  const grid = h("div",{class:"calgrid", role:"grid"},
    ["S","M","T","W","T","F","S"].map(d=>h("span",{class:"calwd", "aria-hidden":"true", text:d})));
  for (let i=0;i<weeks*7;i++){
    const d = new Date(start.getFullYear(), start.getMonth(), start.getDate()+i), key = ymd(d), list = byDay[key] || [];
    const label = d.toLocaleDateString(undefined,{weekday:"long", month:"long", day:"numeric"}) + (list.length ? ", "+list.length+(list.length===1?" event":" events") : "");
    grid.append(h("button",{type:"button", class:"calday"+(d.getMonth()!==m-1?" out":"")+(key===today?" today":"")+(S.evDay===key?" sel":"")+(key<today?" past":""),
        "aria-label":label, "aria-pressed":String(S.evDay===key), onclick:()=>{ S.evDay = S.evDay===key ? null : key; render(); }},
      h("span",{class:"num", text:String(d.getDate())}),
      list.length ? h("span",{class:"dots", "aria-hidden":"true"}, list.slice(0,3).map(e=>h("i",{class:"ev-"+e.kind}))) : null));
  }
  let dayPanel = null;
  if (S.evDay){
    const list = byDay[S.evDay] || eventInstances(S.evDay, S.evDay);
    const off = (D().events||[]).filter(e=>isRepeating(e) && (e.skip_dates||[]).includes(S.evDay));
    dayPanel = h("div",{class:"calpanel stack"},
      h("div",{class:"row"}, h("b",{text:longDay(S.evDay)}),
        h("button",{type:"button", class:"linkbtn", "aria-label":"Close this day", onclick:()=>{ S.evDay = null; render(); }},"Close")),
      list.length ? h("div",{class:"evlist"}, list.map(eventRow)) : off.length ? null : h("p",{class:"hint", style:"margin:0", text:"Nothing planned."}),
      off.map(e=>h("div",{class:"row offrow"}, h("span",{}, h("span",{class:"strike", text:e.title}), h("span",{class:"hint", text:" · called off this date"})),
        isAdmin() && canWrite() && S.evDay >= today ? h("button",{type:"button", class:"linkbtn", onclick:()=>act("api_skip_event",{p_id:e.id, p_day:S.evDay, p_skip:false}, e.title+" is back on")},"Bring back") : null)),
      isAdmin() && canWrite() && S.evDay >= today ? h("button",{type:"button", class:"btn ghost small", style:"align-self:flex-start", onclick:()=>openEventForm(null, S.evDay)},"+ Add an event on this day") : null);
  }
  const thisMonth = today.slice(0,7);
  return h("div",{class:"card calmonth"},
    h("div",{class:"weeknav"},
      h("button",{type:"button", class:"btn ghost small", "aria-label":"Previous month", onclick:()=>step(-1)},"‹"),
      h("div",{class:"weeklabel"}, h("b",{text:first.toLocaleDateString(undefined,{month:"long", year:"numeric"})}),
        S.evMonth!==thisMonth ? h("button",{type:"button", class:"linkbtn", onclick:()=>{ S.evMonth = thisMonth; S.evDay = null; render(); }},"Back to this month") : h("span",{class:"hint", text:"This month"})),
      h("button",{type:"button", class:"btn ghost small", "aria-label":"Next month", onclick:()=>step(1)},"›")),
    grid,
    h("div",{class:"legend", "aria-hidden":"true"}, EVENT_KINDS.map(([id,label])=>h("span",{}, h("i",{class:"ev-"+id}), label))),
    dayPanel);
}
function eventRow(e){
  const pt = partyOfEvent(e);
  const d = parseDay(e.day), promo = e.promote && isAdmin() ? promoTasks(e) : [];
  const done = promo.filter(isDone).length, overdue = promo.filter(isOverdue).length;
  return h("button",{type:"button", class:"evrow ev-"+e.kind+(e.day < shiftDay() ? " past" : ""), onclick:()=>openEventSheet(e)},
    h("span",{class:"evdate", "aria-hidden":"true"},
      h("small",{text:d.toLocaleDateString(undefined,{weekday:"short"})}), h("b",{text:String(d.getDate())}), h("small",{text:d.toLocaleDateString(undefined,{month:"short"})})),
    h("span",{class:"evbody"},
      h("span",{class:"evname", text:e.title}),
      h("span",{class:"line"}, kindTag(e.kind),
        isRepeating(e) ? h("span",{class:"tag plain", text:"↻ "+repeatText(e, true)}) : null,
        pt && pt.status==="hold" ? h("span",{class:"tag plain", text:"On hold"}) : null,
        pt && pt.guests ? h("span",{class:"hint", text:pt.guests+" guests"}) : null,
        eventTime(e) ? h("span",{class:"hint", text:eventTime(e)}) : null,
        promo.length ? h("span",{class:"tag "+(overdue ? "warn" : done===promo.length ? "ok" : "plain"), text: overdue ? "Promotion overdue" : "Promoted "+done+" of "+promo.length}) : null),
      e.notes ? h("span",{class:"hint evnote", text:e.notes}) : null));
}
/* e is one date of an event (from eventInstances), or the event itself */
function openEventSheet(e){
  const pt = partyOfEvent(e); if (pt) return openPartySheet(pt);   // party bookings have their own sheet
  const admin = isAdmin(), promo = e.promote ? promoTasks(e) : [], rep = isRepeating(e), today = shiftDay();
  const reopen = () => { const fresh = eventById(e.id); if (fresh && !$("sheet").hidden) openEventSheet(instanceOf(fresh, e.day)); };
  const kids = [
    h("div",{class:"line"}, kindTag(e.kind), eventWhen(e) ? h("span",{class:"hint", text:eventWhen(e)}) : null),
    h("h2",{class:"evsheet-title", text:e.title}),
    h("div",{class:"evsheet-when"}, h("b",{text:longDay(e.day)}), eventTime(e) ? h("span",{text:eventTime(e)}) : null),
    rep ? h("div",{class:"repline"}, h("span",{text:"↻ "+repeatText(e)+(e.repeat_until ? ", until "+shortDay(e.repeat_until) : "")})) : null,
    e.notes ? h("p",{class:"evnotes", text:e.notes}) : null];
  if (rep){
    const skipped = (e.skip_dates||[]).filter(d=>d >= today);
    if (skipped.length) kids.push(h("div",{class:"stack skips"},
      h("b",{text:"Called off"}),
      skipped.map(d=>h("div",{class:"row"}, h("span",{class:"strike", text:shortDay(d)}),
        admin && canWrite() ? h("button",{type:"button", class:"linkbtn", onclick:async ()=>{ if (await act("api_skip_event",{p_id:e.id, p_day:d, p_skip:false}, "Back on for "+shortDay(d))) reopen(); }},"Bring back") : null))));
  }
  if (admin && e.promote){
    kids.push(h("div",{class:"stack promo"},
      h("b",{text:"Promotion"}),
      promo.length ? promo.map(t=>h("div",{class:"promorow"+(isDone(t)?" done":"")+(isOverdue(t)?" over":"")},
          h("button",{type:"button", class:"check", "data-own-sound":"", "aria-pressed":isDone(t)?"true":"false", "aria-label":(isDone(t)?"Uncheck ":"Check off ")+t.text, disabled:!canWrite(),
            onclick:async ()=>{ await toggleTask(t); reopen(); }}, h("span",{}, svgCheck())),
          h("span",{}, h("span",{text:(PROMO_LEADS.find(x=>x[0]===t.event_lead)||[0,"Promote"])[1]}),
            h("span",{class:"hint", text: isDone(t) ? " · done by "+doneName(t) : " · due "+promoDue(t.due_date)+(isOverdue(t)?" (overdue)":"")}))))
        : h("p",{class:"hint", style:"margin:0", text: e.day < today ? "This event has passed." : "Too close to the event for the promotion reminders."})));
  }
  kids.push(h("p",{class:"hint", style:"margin:0", text:"Added by "+(e.added_by_name || "a manager")}));
  if (admin && canWrite()){
    if (rep && e.day >= today) kids.push(h("button",{type:"button", class:"btn ghost", onclick:ev=>{
      if (ev.target.dataset.armed){ closeSheet(); act("api_skip_event",{p_id:e.id, p_day:e.day, p_skip:true}, "Called off for "+shortDay(e.day)+". The other dates stay."); }
      else { ev.target.dataset.armed = "1"; ev.target.textContent = "Tap again to call off "+shortDay(e.day); } }},"Skip just this date"));
    kids.push(h("div",{class:"inline"},
      h("button",{type:"button", class:"btn ghost small", onclick:()=>{ closeSheet(); openEventForm(eventById(e.id) || e); }}, rep ? "Edit all dates" : "Edit event"),
      h("button",{type:"button", class:"linkbtn warn", id:"delEventBtn", onclick:ev=>{
        if (ev.target.dataset.armed){ closeSheet(); act("api_remove_event",{p_id:e.id},"Event removed"); }
        else { ev.target.dataset.armed = "1"; ev.target.textContent = rep ? "Tap again to remove every date" : promo.length ? "Tap again: remove it and its promotion tasks" : "Tap again to remove"; } }},
        rep ? "Remove all dates" : "Remove event")));
  }
  kids.push(h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Close"));
  openSheet(...kids);
}
/* managers: add or change an event (for a repeating one, the whole series) */
function openEventForm(e, dateStr){
  const today = shiftDay();
  let kind = e ? e.kind : "standard", repeat = e && e.repeat ? e.repeat : "none";
  const title = h("input",{type:"text", id:"evTitle", maxlength:"120", placeholder:"e.g. Eagles watch party", value:e ? e.title : ""});
  const date = h("input",{type:"date", id:"evDate", value:e ? e.day : (dateStr || today)});
  const st = h("input",{type:"time", id:"evStart", value:e ? hhmm(e.start_time) : ""});
  const en = h("input",{type:"time", id:"evEnd", value:e ? hhmm(e.end_time) : ""});
  const notes = h("textarea",{id:"evNotes", rows:"3", maxlength:"1000", placeholder:"Band, host, menu specials, setup, who's working it…"}, e ? e.notes : "");
  const repSel = h("select",{id:"evRepeat", onchange:()=>{ repeat = repSel.value; sync(); }});
  const until = h("input",{type:"date", id:"evUntil", value:e && e.repeat_until ? e.repeat_until : ""});
  const untilBox = h("label",{class:"lbl", for:"evUntil"}, "Last date (optional)", until);
  const repBox = h("div",{class:"stack repbox"}, h("label",{class:"lbl", for:"evRepeat"}, "Repeat", repSel), untilBox);
  const dateLbl = h("span",{text:"Date"});
  /* "Promote it": starts on for Entertainment, off otherwise; once tapped, it stays how you set it */
  let promote = e ? !!e.promote : kind==="entertainment", promoTouched = !!e;
  const promoBox = h("input",{type:"checkbox", id:"evPromote", checked:promote, onchange:()=>{ promote = promoBox.checked; promoTouched = true; sync(); }});
  const promoNote = h("p",{class:"hint", style:"margin:0"});
  const promoWrap = h("div",{class:"promobox stack"},
    h("label",{class:"toggle", for:"evPromote"}, promoBox, h("span",{}, h("b",{text:"📣 Promote it"}), h("span",{class:"hint", text:" · reminders for managers"}))),
    promoNote);
  const promoHint = h("div",{class:"promohint"});
  const sync = () => {
    /* repeat choices follow the date ("Every Tuesday"); only Standard events repeat */
    const opts = repeatOptions(date.value);
    if (!opts.some(o=>o[0]===repeat)) repeat = repeat.startsWith("monthly") ? "monthly" : "none";
    repSel.replaceChildren(...opts.map(([id,label])=>h("option",{value:id, selected:repeat===id}, label)));
    repBox.hidden = kind!=="standard";
    const reps = kind==="standard" && repeat!=="none";
    untilBox.hidden = !reps; until.min = date.value || "";
    dateLbl.textContent = reps ? "First date" : "Date";
    if (!promoTouched){ promote = kind==="entertainment"; promoBox.checked = promote; }
    promoBox.disabled = reps;
    promoNote.textContent = reps ? "Repeating events can't get promotion reminders." : "";
    promoNote.hidden = !reps;
    const on = promote && !reps;
    promoHint.hidden = !on;
    if (!on || !date.value) return promoHint.replaceChildren();
    promoHint.replaceChildren(
      h("b",{text:"Managers get a starred task to promote it:"}),
      h("ul",{}, PROMO_LEADS.map(([n,label])=>{ const due = addDays(date.value, -n), past = due < today;
        return h("li",{class:past?"past":""}, label+": "+shortDay(due)+(past ? " (already passed, skipped)" : "")); })));
  };
  date.addEventListener("change", sync); date.addEventListener("input", sync);
  const kinds = h("div",{class:"kindpick", role:"radiogroup", "aria-label":"Type of event"},
    EVENT_KINDS.map(([id,label,icon])=>h("label",{class:"kindopt ev-"+id},
      h("input",{type:"radio", name:"evKind", value:id, checked:kind===id, onchange:()=>{ kind = id; sync(); }}),
      h("span",{class:"ki", "aria-hidden":"true", text:icon}), h("span",{text:label}))));
  sync();
  const err = h("p",{class:"loginerr", role:"alert"});
  openSheet(
    h("h2",{text:e ? (isRepeating(e) ? "Edit all dates" : "Edit event") : "Add event"}),
    h("label",{class:"lbl", for:"evTitle"}, "What's happening", title),
    h("fieldset",{class:"choices"}, h("legend",{class:"lbl", text:"Type"}), kinds),
    h("label",{class:"lbl", for:"evDate"}, dateLbl, date),
    repBox,
    h("div",{class:"inline"}, h("label",{class:"lbl", for:"evStart", style:"flex:1"}, "Starts (optional)", st), h("label",{class:"lbl", for:"evEnd", style:"flex:1"}, "Ends (optional)", en)),
    h("label",{class:"lbl", for:"evNotes"}, "Details (optional)", notes),
    promoWrap,
    promoHint,
    err,
    h("button",{type:"button", class:"btn", onclick:async ev=>{
      if (!title.value.trim()){ err.textContent = "Give the event a name."; title.focus(); return; }
      if (!date.value){ err.textContent = "Pick a date."; return; }
      const rp = kind==="standard" ? repeat : "none", un = rp!=="none" && until.value ? until.value : null;
      if (un && un < date.value){ err.textContent = "The last date has to be on or after the first date."; return; }
      ev.target.disabled = true; err.textContent = "";
      try {
        await call("api_save_event",{p_id:e ? e.id : null, p_title:title.value, p_kind:kind, p_day:date.value, p_start:st.value||null, p_end:en.value||null, p_notes:notes.value, p_repeat:rp, p_until:un, p_promote:promote && rp==="none"});
        closeSheet(); play("ok");
        const n = promote && rp==="none" && !e ? PROMO_LEADS.filter(([n])=>addDays(date.value,-n) >= today).length : 0;
        toast(e ? "Event saved" : n ? "Event added, plus "+n+" promotion "+(n===1?"task":"tasks")+" for managers" : rp!=="none" ? "Repeating event added" : "Event added");
        S.evMonth = date.value.slice(0,7); S.evDay = null;
        await refresh();
      } catch(x){ if (x.code==="not_logged_in") return logOut("You've been logged out. Enter your number again."); err.textContent = errMsg(x); ev.target.disabled = false; }
    }}, e ? "Save" : "Add event"),
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Cancel"));
  if (!e) title.focus();
}
