/* JT Brewski's staff app · The Tasks tab: the Tonight chalkboard, the task list, adding and editing tasks. */
"use strict";

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

/* tasks this person sees: ones for everyone, plus ones for roles on their side of the pub */
/* a task assigned to one person shows only for them (and managers); the rest go by role */
const visibleTasks = () => D().tasks.filter(t=>t.assignee ? (t.assignee===me().id || isAdmin()) : (!t.role_id || canSeeRole(roleById(t.role_id))));
const isMineTask = t => { const m = me(); return t.assignee ? t.assignee===m.id : (!t.role_id || (m.roles||[]).includes(t.role_id)); };
const taskSort = (a,b)=>Number(!!b.important)-Number(!!a.important) || (taskDeadline(a)||Infinity)-(taskDeadline(b)||Infinity) || a.text.localeCompare(b.text);

/* ---------- the Tonight card: the top of the Tasks tab ---------- */
const ICONS = {
  clock:'<circle cx="12" cy="12" r="9"/><path d="M12 7v5l3 2"/>',
  cal:'<rect x="3" y="4.5" width="18" height="16.5" rx="2.5"/><path d="M8 2.5v4M16 2.5v4M3 10h18"/>',
  box:'<path d="M21 8l-9-5-9 5 9 5 9-5z"/><path d="M3 8v8l9 5 9-5V8"/><path d="M12 13v8"/>',
  lock:'<rect x="5" y="11" width="14" height="10" rx="2"/><path d="M8 11V7a4 4 0 0 1 8 0v4"/>',
  hand:'<path d="M12 9v4M12 17h.01"/><path d="M10.3 3.9L1.8 18a2 2 0 0 0 1.7 3h17a2 2 0 0 0 1.7-3L13.7 3.9a2 2 0 0 0-3.4 0z"/>'
};
function icon(name){ const s = document.createElementNS("http://www.w3.org/2000/svg","svg"); s.setAttribute("viewBox","0 0 24 24"); s.setAttribute("aria-hidden","true");
  s.setAttribute("fill","none"); s.setAttribute("stroke","currentColor"); s.setAttribute("stroke-width","2"); s.setAttribute("stroke-linecap","round"); s.setAttribute("stroke-linejoin","round");
  s.innerHTML = ICONS[name] || ""; return s; }
const compactTime = t => (t||"").replace(/:00(?=\s?[AP]M)/gi, "").replace(" – Close", " – close");   // "5:00 PM – Close" -> "5 PM – close"
/* a line on the chalkboard: label, dotted leader, value — like a menu */
function boardRow(cls, label, value, onclick, hot){
  return h("button",{type:"button", class:"bd-row "+cls+(hot?" hot":""), onclick},
    h("span",{class:"bd-l", text:label}), h("span",{class:"bd-dots", "aria-hidden":"true"}), h("span",{class:"bd-v", text:value}));
}
/* ---------- the greeting: changes with the day, the hour and what's on tonight ----------
   Picks are steady for the whole day (the same person sees the same words all day) so nothing flickers. */
function pickFor(seed, list){ let x = 0; for (const c of seed) x = (x*31 + c.charCodeAt(0)) >>> 0; return list[x % list.length]; }
function holidayHello(day){
  const d = parseDay(day), md = day.slice(5), y = d.getFullYear();
  const nov1 = new Date(y, 10, 1), thanks = 1 + ((4 - nov1.getDay() + 7) % 7) + 21;   // the fourth Thursday of November
  const tg = y+"-11-"+String(thanks).padStart(2,"0");
  return {"03-17":"Happy St. Patrick’s Day", "07-04":"Happy Fourth", "10-31":"Happy Halloween", "12-24":"Merry Christmas Eve",
          "12-25":"Merry Christmas", "12-31":"Happy New Year’s Eve", "01-01":"Happy New Year"}[md]
      || (day===tg ? "Happy Thanksgiving" : day===addDays(tg,-1) ? "Happy Thanksgiving Eve" : null);
}
function greeting(now, day){
  const seed = day + (me().id||""), hr = now.getHours(), wd = parseDay(day).getDay();
  const hol = holidayHello(day); if (hol) return hol;
  if (hr >= 22 || hr < 5) return pickFor(seed, ["Late one tonight", "Still at it", "Home stretch", "Night owl hours"]);
  if (wd===5 && hr >= 11) return "Happy Friday";
  if (wd===6) return "Happy Saturday";
  if (wd===0 && hr >= 10) return pickFor(seed, ["Happy Sunday", "Sunday Funday"]);
  if (hr < 12) return pickFor(seed, ["Good morning", "Morning", "Rise and shine"]);
  if (hr < 17) return pickFor(seed, ["Good afternoon", "Afternoon", "Hey there"]);
  return pickFor(seed, ["Good evening", "Evening", "Hey there"]);
}
/* one line on what's happening today */
function vibeLine(day, now){
  if (now.getHours() >= 23 || now.getHours() < 5) return null;
  const evs = eventInstances(day, day), parties = evs.filter(e=>e.kind==="party"), rest = evs.filter(e=>e.kind!=="party");
  const game = evs.some(e=>/\b(eagles|phillies|sixers|76ers|flyers|union)\b/i.test(e.title||""));
  const at = e => e.start_time ? " at "+compactTime(fmtClock(e.start_time)) : "";
  if (!evs.length) return pickFor(day, ["Nothing on the calendar tonight", "No events tonight. Just good beer.", "A quiet one on the calendar"]);
  if (evs.length===1){ const e = evs[0]; return (game ? "Game day: " : e.kind==="party" ? "Party tonight: " : "Tonight: ")+e.title+at(e); }
  const bits = [];
  if (parties.length) bits.push(parties.length===1 ? "a party" : parties.length+" parties");
  rest.slice(0, 2).forEach(e=>bits.push(e.title));
  if (rest.length > 2) bits.push(rest.length-2+" more");
  return (game ? "Game day! " : "Busy one tonight: ")+bits.slice(0,-1).join(", ")+(bits.length>1 ? " and " : "")+bits[bits.length-1];
}
const ALL_DONE = ["All done for today 🍻", "Every box checked. Cheers 🍻", "Clean sweep today 🍻", "That’s everything. Nice work 🍻"];
function tonightCard(all){
  const m = me(), now = new Date(), today = shiftDay();
  const p = progressOf(all.filter(countsToday)), over = all.filter(isOverdue).length;
  const rows = [], wd = iso => new Date(iso).toLocaleDateString([], {weekday:"short"});
  /* your shift */
  const next = myShifts().filter(s=>shiftEndDate(s) > now).sort((a,b)=>a.start_at.localeCompare(b.start_at))[0];
  if (next){
    const onNow = new Date(next.start_at) <= now, isToday = shiftDay(new Date(next.start_at))===today;
    rows.push(boardRow("tn-shift", onNow ? "On now" : isToday ? "Your shift" : "Next shift",
      onNow ? "until "+compactTime(next.end_at ? tFmt(next.end_at) : "close")
            : (isToday ? "" : shiftDayLabel2(next.start_at)+" · ")+compactTime(shiftRange(next)),
      ()=>go("schedule")));
  }
  /* shifts you could pick up */
  const open = forYouShifts().sort((a,b)=>a.start_at.localeCompare(b.start_at));
  if (open.length===1){
    const s = open[0];
    rows.push(boardRow("tn-cover", s.staff_id ? "Cover "+staffName(s.staff_id).split(/\s+/)[0]+"'s shift?" : "Take the open shift?",
      wd(s.start_at)+" "+compactTime(tFmt(s.start_at)), ()=>go("schedule"), true));
  } else if (open.length) rows.push(boardRow("tn-cover", open.length+" shifts need cover", "See them", ()=>go("schedule"), true));
  /* events today or tomorrow */
  for (const e of eventInstances(today, addDays(today,1)).slice(0, 3)){
    const t = compactTime(e.start_time ? fmtClock(e.start_time) : "");
    rows.push(boardRow("tn-event ev-"+e.kind, e.title, e.day===today ? (t || "Today") : "Tomorrow"+(t ? " "+t : ""), ()=>{ go("events"); openEventSheet(e); }));
  }
  /* cash-out at close */
  rows.push(...cashBoardRows(today));
  const ar = alertsBoardRow(); if (ar) rows.unshift(ar);
  const dr = dailyCashBoardRow(today); if (dr) rows.push(dr);
  /* managers: the next order deadline */
  if (isAdmin() && D().suppliers.length){
    const nx = suppliersByDeadline().find(x=>x.d && !x.ordered);
    if (nx) rows.push(boardRow("tn-order", "Order "+nx.s.name, compactTime(dueText(nx.d).split(" · ")[0]), ()=>go("inventory"), nx.d - now < 24*3600e3));
  }
  const hello = greeting(now, today), vibe = vibeLine(today, now);
  const left = p.total - p.done;
  return h("div",{class:"tonight"},
    h("section",{class:"tn-top", "aria-label":"Today"},
      h("div",{class:"tn-hello"},
        h("span",{class:"eyebrow", text:parseDay(today).toLocaleDateString(undefined,{weekday:"long"})+" · "+parseDay(today).toLocaleDateString(undefined,{month:"long", day:"numeric"})}),
        h("h2",{}, hello+", ", h("i",{text:(m.name||"").split(/\s+/)[0]})),
        h("p",{class:"tn-sum"},
          h("span",{}, !p.total ? "Nothing due today" : !left ? pickFor(today+"done", ALL_DONE) : [roll("tn-done", p.done, {fromZero:true}), " of "+p.total+" done"]),
          over ? h("span",{class:"tn-over"}, " · ", roll("tn-over", over), " overdue") : null),
        vibe ? h("p",{class:"tn-vibe", text:vibe}) : null),
      h("div",{class:"tn-stein", title:p.done+" of "+p.total+" done"}, stein(p.pct))),
    rows.length ? h("section",{class:"board", "aria-label":"Tonight at Brewski's"},
      h("h3",{class:"bd-title", text:"Tonight at Brewski's"}), rows) : null);
}

function viewOverview(){
  const out = [], d = D(), admin = isAdmin();
  const all = visibleTasks();
  out.push(tonightCard(all));
  out.push(...alertsSection());

  out.push(h("div",{class:"sec-head tasks-head"}, h("h2",{class:"sectitle", text:"Tasks"}),
    admin && canWrite() && !S.addingTask ? h("button",{type:"button", class:"btn small", onclick:()=>{ S.addingTask = true; render(); $("newTask")?.focus(); }},"Add task") : null));
  checkPushOnce();
  if (S.push.loaded && !(S.push.sub && S.push.prefs)) out.push(h("button",{type:"button", class:"linkbtn alertlink tasks-alert", onclick:openNotify},"🔔 Get alerts on this phone when new tasks are added"));
  if (admin && S.addingTask) out.push(addTaskForm());

  if (!all.length){
    out.push(emptyCard("No tasks yet", admin
      ? "Add the things worth keeping an eye on: deep cleans, repairs, inspections, deliveries, deadlines. Star the ones that matter most. Everyday open and close duties don't need to go here."
      : "When a manager adds a task for you or your side of the pub, it shows up here."));
    out.push(activitySection());
    return out;
  }
  const starred = all.filter(t=>t.important && !isDone(t)).length;
  out.push(h("div",{class:"chips", role:"group", "aria-label":"Show"},
    [["all","All tasks"],["mine","For me"],["important",["★ Important", starred ? [" · ", roll("starred", starred)] : null]]].map(([id,label])=>
      h("button",{type:"button", class:"chip", "aria-pressed":String(S.taskFilter===id), onclick:()=>{ S.taskFilter = id; render(); }}, label))));
  let list = all;
  if (S.taskFilter==="mine") list = list.filter(isMineTask);
  if (S.taskFilter==="important") list = list.filter(t=>t.important);
  const over = list.filter(isOverdue).sort(taskSort);
  const today = list.filter(t=>bucket(t)==="now" && !isOverdue(t)).sort(taskSort);
  const later = list.filter(t=>bucket(t)==="later").sort(taskSort);
  const done = list.filter(t=>bucket(t)==="done").sort((a,b)=>String(b.done_at||"").localeCompare(String(a.done_at||"")));
  const group = (title, items, cls) => items.length ? [h("div",{class:"divider"+(cls?" "+cls:""), text:title+" · "+items.length}), items.map(taskRow)] : [];
  out.push(h("div",{class:"list"},
    group("Overdue", over, "over"),
    group("To do", today),
    group("Coming up", later),
    done.length ? h("button",{type:"button", class:"divider fold", "aria-expanded":String(S.showDone), onclick:()=>{ S.showDone = !S.showDone; render(); }},
      "Done · "+done.length+(S.showDone ? "  ▾" : "  ▸")) : null,
    S.showDone ? done.slice(0, 30).map(taskRow) : null,
    !over.length && !today.length && !later.length && !(done.length && S.showDone)
      ? h("div",{class:"task"}, h("span"), h("span",{class:"hint", text: S.taskFilter==="important" ? "No starred tasks open." : S.taskFilter==="mine" ? "Nothing open for you." : "All caught up."})) : null));
  out.push(activitySection());
  return out;
}
/* the activity feed's entries this person may see, newest first */
function activityEvents(data){
  const d = data || D(), admin = isAdmin();
  const VERB = {done:" checked off “%”", undone:" unchecked “%”", added:" added “%”", removed:" removed “%”", edited:" edited “%”", count:" counted %", ordered:" placed the % order", tapped:" put % on tap", kicked:" marked % kicked", shift_posted:" asked for coverage on %", shift_taken:" is covering %", skipped:" called off %", unskipped:" brought back %",
                inquiry:" asked about a party: %", held:" put a hold on %", booked:" booked %", declined:" declined %", cancelled:" cancelled %", reopened:" reopened %", deposit:" took the deposit for %", cashout:" cashed out %", recount:" changed the cash-out for %", replenished:" replenished %", unreplenished:" un-marked %", alerted:" alerted %", handled:" handled %"};
  /* staff only see activity from their side of the pub, plus inventory counts */
  const placeOk = admin ? ()=>true : (()=>{ const ok = new Set(d.roles.filter(canSeeRole).map(r=>r.name)); ok.add("Inventory"); ok.add("Schedule"); ok.add("Tasks"); ok.add("Events"); return place=>ok.has(place); })();
  /* staff don't see activity on tasks assigned to someone else */
  const othersTasks = admin ? new Set() : new Set(d.tasks.filter(t=>t.assignee && t.assignee!==me().id).map(t=>t.text));
  const TASK_KINDS = new Set(["added","edited","removed","done","undone"]);
  return d.log.filter(l=>placeOk(l.place||"") && !(TASK_KINDS.has(l.kind) && othersTasks.has(l.text))).map(l=>({id:l.id, at:l.at, whoId:l.who, kind:l.kind, text:l.text||"", who:l.who_name || staffName(l.who), what:(VERB[l.kind]||" updated %").replace("%", l.text||""), where:l.place==="Schedule" ? "Shifts" : (l.place||"")}));   // the Schedule tab is called Shifts now
}
function activitySection(){
  const admin = isAdmin();
  const ev = activityEvents();
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

function canEditTask(t){ return canWrite() && isAdmin(); }

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
  if (d.repeat==="daily") return "Due every day"+t+". It's flagged overdue after that.";
  if (!d.due_date) return d.repeat==="once" ? "No due date: it stays on the list until someone checks it off." : "Pick the first due date.";
  const day = parseDay(d.due_date);
  const wd = day.toLocaleDateString(undefined,{weekday:"long"});
  const first = day.toLocaleDateString(undefined,{month:"short", day:"numeric"});
  if (d.repeat==="weekly") return "Due every "+wd+t+", starting "+first+".";
  if (d.repeat==="biweekly") return "Due every other "+wd+t+", starting "+first+".";
  if (d.repeat==="monthly") return "Due on the "+ordinal(day.getDate())+" of every month"+t+", starting "+first+". Short months use their last day.";
  return "Due "+first+t+".";
}
/* who a task can be for: people with that role, or anyone when it's for everyone */
function assigneeOptions(roleId){ const pool = roleId ? roleStaff(roleId) : []; return (pool.length ? pool : D().staff).slice().sort((a,b)=>a.name.localeCompare(b.name)); }
function taskFields(d, pre){
  return [
    h("label",{class:"lbl full", for:pre+"Text"}, "Task", h("input",{type:"text", id:pre+"Text", placeholder:"e.g. Deep clean the fryer", value:d.text, oninput:e=>d.text=e.target.value})),
    h("label",{class:"toggle star-toggle full", for:pre+"Star"}, h("input",{type:"checkbox", id:pre+"Star", checked:!!d.important, onchange:e=>d.important=e.target.checked}), "★ Important (pinned to the top)"),
    h("label",{class:"lbl", for:pre+"Role"}, "Who it's for",
      h("select",{id:pre+"Role", onchange:e=>{ d.role_id = e.target.value; if (d.assignee && d.role_id && !roleStaff(d.role_id).some(p=>p.id===d.assignee)) d.assignee = ""; render(); }},
        h("option",{value:"", selected:!d.role_id},"Everyone"),
        sortedRoles().map(r=>h("option",{value:r.id, selected:d.role_id===r.id}, r.name)))),
    h("label",{class:"lbl", for:pre+"Assignee"}, "Person (optional)",
      h("select",{id:pre+"Assignee", onchange:e=>d.assignee=e.target.value},
        h("option",{value:"", selected:!d.assignee}, d.role_id ? "Anyone in that role" : "Anyone"),
        assigneeOptions(d.role_id).map(s=>h("option",{value:s.id, selected:d.assignee===s.id}, s.name)))),
    scheduleFields(d, pre)];
}
function taskArgs(d){
  return {p_text:d.text, p_assignee:d.assignee||null, p_repeat:d.repeat, p_due_date:d.repeat==="daily" ? null : (d.due_date||null),
          p_due_time:d.due_time||null, p_role_id:d.role_id||"", p_important:!!d.important};
}
function addTaskForm(){
  const d = S.draft;
  return h("form",{class:"add", onsubmit:async e=>{ e.preventDefault(); if (!d.text.trim()) return;
      if (RECURRING.has(d.repeat) && !d.due_date) return toast("Pick the first due date.");
      const a = taskArgs(d);
      if (await act("api_add_task",{p_role_id:a.p_role_id, p_text:a.p_text, p_assignee:a.p_assignee, p_repeat:a.p_repeat, p_due_date:a.p_due_date, p_due_time:a.p_due_time, p_important:a.p_important}, "Task added")){
        S.draft = {text:"", assignee:"", repeat:"once", due_date:"", due_time:"", role_id:"", important:false}; S.addingTask = false; render(); } }},
    taskFields(d, "new"),
    h("div",{class:"inline full"},
      h("button",{type:"submit", class:"btn small", disabled:!canWrite()},"Add task"),
      h("button",{type:"button", class:"btn ghost small", onclick:()=>{ S.addingTask = false; render(); }},"Cancel")));
}
function editTaskForm(t){
  const d = S.editDraft;
  return h("form",{class:"add edit-task", onsubmit:async e=>{ e.preventDefault(); if (!d.text.trim()) return;
      if (RECURRING.has(d.repeat) && !d.due_date) return toast("Pick the first due date.");
      if (await act("api_update_task",{p_id:t.id, ...taskArgs(d)},"Task updated")){ S.editTask = null; render(); } }},
    taskFields(d, "ed"),
    h("div",{class:"inline full"},
      h("button",{type:"submit", class:"btn small"},"Save"),
      h("button",{type:"button", class:"btn ghost small", onclick:()=>{ S.editTask = null; render(); }},"Cancel")));
}

function taskRow(t){
  if (S.editTask===t.id && S.editDraft) return h("div",{class:"task editing"}, editTaskForm(t));
  const role = roleById(t.role_id), done = isDone(t), over = isOverdue(t), due = dueLine(t), editable = canEditTask(t);
  const ck = "task:"+t.id;
  return h("div",{class:"task"+(done?" done":"")+(over?" overdue":"")+(t.important?" important":"")+(S.fx.task===t.id ? (done?" just-done":" just-undone") : "")+(flashing("task:"+t.id) ? " live-flash" : ""), "data-task":t.id},
    h("button",{type:"button", class:"check", "data-own-sound":"", "aria-pressed":done?"true":"false", "aria-label":(done?"Uncheck ":"Check off ")+t.text, disabled:!canWrite(), onclick:()=>toggleTask(t)}, h("span",{}, svgCheck())),
    h("div",{style:"min-width:0"},
      h("div",{class:"text"}, t.important ? h("span",{class:"star", "aria-label":"Important", title:"Important"},"★ ") : null, t.text),
      h("div",{class:"tmeta"},
        h("div",{class:"line"},
          role ? h("span",{class:"tag "+role.section, text:role.name}) : h("span",{class:"tag plain", text:"Everyone"}),
          t.assignee ? h("span",{class:"tag plain", text:"For "+staffName(t.assignee)}) : null,
          t.party_id && partyById(t.party_id) ? h("button",{type:"button", class:"tag ev-party evlink", onclick:()=>{ go("events"); openPartySheet(partyById(t.party_id)); }},"🎉 See party") : null,
          t.event_id && eventById(t.event_id) ? h("button",{type:"button", class:"tag ev-"+eventById(t.event_id).kind+" evlink", onclick:()=>{ const e = eventById(t.event_id); go("events"); if (e) openEventSheet(e); }},"📣 See event") : null,
          t.repeat!=="once" ? h("span",{class:"tag plain", text:repeatLabel(t)}) : null,
          due ? h("span",{class:"due-line "+due.cls, text:due.text}) : null),
        done ? h("div",{class:"line ok", text:"✓ Done by "+doneName(t)+" · "+when(t.done_at)}) : null,
        editable ? h("div",{class:"line"},
          h("button",{type:"button", class:"linkbtn", onclick:()=>act("api_star_task",{p_id:t.id, p_important:!t.important}, t.important ? "Unstarred" : "Starred")}, t.important ? "Unstar" : "★ Star"),
          h("button",{type:"button", class:"linkbtn", onclick:()=>{ S.editTask = t.id; S.editDraft = {text:t.text, assignee:t.assignee||"", repeat:t.repeat, due_date:t.due_date||"", due_time:hhmm(t.due_time), role_id:t.role_id||"", important:!!t.important}; S.confirm = null; render(); $("edText")?.focus(); }},"Edit"),
          S.confirm===ck ? h("button",{type:"button", class:"linkbtn warn", onclick:async ()=>{ S.confirm=null; await act("api_remove_task",{p_id:t.id},"Task removed"); }},"Tap again to remove")
                         : h("button",{type:"button", class:"linkbtn", onclick:()=>askConfirm(ck)},"Remove"),
          h("span",{class:"hint", text:"Added by "+addedName(t)})) : null)));
}
