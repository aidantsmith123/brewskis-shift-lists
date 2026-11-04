/* JT Brewski's staff app · The Drawers tab: daily cash (Aidan, Tom and Mandy only) and the drawer cash-out. */
"use strict";

/* ---------- daily cash ----------
   The day's cash sales, payouts and the COH (cash on hand, counted). Only Aidan, Tom and Mandy: the server sends it to
   nobody else and refuses anyone else's changes, so me().cash_book here only decides what to draw. */
const canCashBook = () => !!(me() && me().cash_book);
const dailyCash = () => D().daily_cash || [];
const dcFor = day => dailyCash().find(d=>d.day===day);
const signed = n => (Number(n) < 0 ? "−" : "")+cash(n);
const dcPayees = () => { const seen = new Map(); dailyCash().forEach(d=>(d.payouts||[]).forEach(p=>{ const k = (p.who||"").trim(); if (k && !seen.has(k.toLowerCase())) seen.set(k.toLowerCase(), k); })); return [...seen.values()]; };
function scrollToDailyCash(){ requestAnimationFrame(()=>{ const el = $("dailyCash"); if (el) el.scrollIntoView({block:"start", behavior:"smooth"}); }); }
function dailyCashBoardRow(today){
  if (!canCashBook()) return null;
  const y = addDays(today, -1);
  if (dcFor(y)) return null;
  return boardRow("tn-dcash", "Daily cash", "Enter "+weekdayName(y, "short")+"’s numbers", ()=>{ go("cash"); openDailyCashForm(y); });
}
function dcStats(d){
  return h("div",{class:"cashstats"},
    h("div",{class:"cstat"}, h("small",{text:"Cash sales"}), h("b",{}, roll("dc-sales", cash(d.cash_sales)))),
    h("div",{class:"cstat"}, h("small",{text:"Payouts"}), h("b",{}, roll("dc-pay", cash(d.payouts_total)))),
    h("div",{class:"cstat"+(Number(d.left_over) < 0 ? " neg" : "")}, h("small",{text:"COH"}), h("b",{}, roll("dc-coh", signed(d.left_over)))));
}
function dailyCashCard(){
  const list = dailyCash(), latest = list[0];
  const sec = h("section",{class:"card stack dcash", id:"dailyCash"},
    h("div",{class:"row"}, h("h2",{text:"Daily cash"}),
      canWrite() ? h("button",{type:"button", class:"btn small", onclick:()=>openDailyCashForm(null)},"+ Enter a day") : null),
    h("p",{class:"hint dcpriv"}, icon("lock"), h("span",{text:"Only Aidan, Tom and Mandy can see this."})));
  if (!latest){ sec.append(h("p",{class:"hint", style:"margin:0", text:"Enter each day’s cash sales, payouts and COH (cash on hand). The other two get a notification with the numbers."})); return sec; }
  sec.append(h("button",{type:"button", class:"dclatest", onclick:()=>openDailyCashForm(latest.day)},
    h("div",{class:"row"}, h("b",{text:longDay(latest.day)}), h("span",{class:"hint", text:(latest.by_name||"")+" · "+when(latest.at)})),
    dcStats(latest),
    (latest.payouts||[]).length ? h("ul",{class:"dcpays"}, latest.payouts.map(p=>h("li",{}, h("span",{text:p.who}), h("b",{text:cash(p.amount)})))) : null,
    latest.note ? h("p",{class:"hint", style:"margin:0", text:"“"+latest.note+"”"}) : null));
  const rest = list.slice(1, 15);
  if (rest.length) sec.append(h("div",{class:"stack", style:"gap:6px"}, h("b",{class:"subhead", text:"Earlier days"}),
    rest.map(d=>h("button",{type:"button", class:"cashrow", onclick:()=>openDailyCashForm(d.day)},
      h("span",{class:"t"}, h("b",{text:shortDay(d.day)}),
        h("span",{class:"hint", text:"Sales "+cash(d.cash_sales)+" · Payouts "+cash(d.payouts_total)+" · COH "+signed(d.left_over)}))))));
  sec.append(h("button",{type:"button", class:"btn ghost small", style:"align-self:flex-start", onclick:downloadDailyCash},"Download CSV"));
  return sec;
}
async function downloadDailyCash(){
  const q = v => { const s = String(v==null ? "" : v); return /[",\n]/.test(s) ? '"'+s.replace(/"/g,'""')+'"' : s; };
  const rows = [["Date","Cash sales","Payouts total","Payouts","COH","Note","Entered by"]];
  dailyCash().slice().sort((a,b)=>a.day.localeCompare(b.day)).forEach(d=>rows.push([d.day, d.cash_sales, d.payouts_total,
    (d.payouts||[]).map(p=>p.who+" "+p.amount).join("; "), d.left_over, d.note, d.by_name]));
  const name = "brewskis-daily-cash-"+shiftDay()+".csv", file = new File([rows.map(r=>r.map(q).join(",")).join("\n")], name, {type:"text/csv"});
  try { if (navigator.canShare && navigator.canShare({files:[file]})){ await navigator.share({files:[file], title:"Daily cash"}); return; } } catch(e){ if (e && e.name==="AbortError") return; }
  const a = h("a",{href:URL.createObjectURL(file), download:name}); document.body.append(a); a.click(); setTimeout(()=>{ URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}
function openDailyCashForm(day){
  if (!canCashBook()) return;
  const today = shiftDay();
  day = day || (dcFor(addDays(today,-1)) ? today : addDays(today,-1));
  const prev = dcFor(day);
  const num = (id, val, extra) => h("input", Object.assign({type:"number", id, min:"0", step:"0.01", inputmode:"decimal", value: val==null ? "" : val, autocomplete:"off"}, extra||{}));
  const date = h("input",{type:"date", id:"dcDay", value:day, max:today});
  const sales = num("dcSales", prev ? prev.cash_sales : null, {placeholder:"0.00"});
  const left = num("dcLeft", prev ? prev.left_over : null, {placeholder:"0.00", min:null});
  const note = h("textarea",{id:"dcNote", rows:"2", maxlength:"1000", placeholder:"Optional"}, prev ? prev.note : "");
  const rowsBox = h("div",{class:"stack dcrows", style:"gap:8px"});
  const total = h("b",{}), dup = h("p",{class:"hint warnline", role:"status"});
  const sync = () => {
    let t = 0; rowsBox.querySelectorAll(".dcamt").forEach(i=>{ const v = parseFloat(i.value); if (!isNaN(v) && v > 0) t += v; });
    total.textContent = cash(t);
    const other = date.value && date.value!==day ? dcFor(date.value) : null;
    dup.textContent = other ? "There’s already an entry for "+shortDay(date.value)+". Saving replaces it." : ""; dup.hidden = !other;
  };
  const addRow = (p) => {
    const who = h("input",{type:"text", class:"dcwho", maxlength:"60", placeholder:"Who or what", list:"dcPayees", value:p ? p.who : "", "aria-label":"Paid to"});
    const amt = h("input",{type:"number", class:"dcamt", min:"0", step:"0.01", inputmode:"decimal", placeholder:"0.00", value:p ? p.amount : "", "aria-label":"Amount", oninput:sync});
    const row = h("div",{class:"dcrow"}, who, amt, h("button",{type:"button", class:"dcdel", "aria-label":"Remove this payout", onclick:()=>{ row.remove(); if (!rowsBox.children.length) addRow(); sync(); }}, "×"));
    rowsBox.append(row); return who;
  };
  (prev && prev.payouts && prev.payouts.length ? prev.payouts : [null]).forEach(p=>addRow(p));
  date.addEventListener("change", sync); sync();
  const err = h("p",{class:"loginerr", role:"alert"});
  openSheet(
    h("h2",{text:prev ? "Daily cash · "+shortDay(day) : "Enter daily cash"}),
    h("p",{class:"hint dcpriv", style:"margin:-4px 0 0"}, icon("lock"), h("span",{text:"Only Aidan, Tom and Mandy can see this."})),
    h("datalist",{id:"dcPayees"}, dcPayees().map(n=>h("option",{value:n}))),
    h("div",{class:"inline"}, h("label",{class:"lbl", for:"dcDay", style:"flex:1"}, "Day", date), h("label",{class:"lbl", for:"dcSales", style:"flex:1"}, "Cash sales ($)", sales)),
    dup,
    h("fieldset",{class:"choices"}, h("legend",{class:"lbl", text:"Payouts"}), rowsBox,
      h("div",{class:"row", style:"margin-top:8px"},
        h("button",{type:"button", class:"linkbtn", onclick:()=>{ addRow().focus(); }},"+ Add payout"),
        h("span",{class:"hint"}, "Total ", total))),
    h("label",{class:"lbl", for:"dcLeft"}, "COH ($)", left),
    h("p",{class:"hint", style:"margin:-6px 0 0", text:"Cash on hand: what you counted after the payouts."}),
    h("label",{class:"lbl", for:"dcNote"}, "Note", note),
    err,
    h("button",{type:"button", class:"btn", onclick:async ev=>{
      if (!date.value){ err.textContent = "Pick the day."; return; }
      if (sales.value.trim()===""){ err.textContent = "Enter the cash sales."; sales.focus(); return; }
      if (left.value.trim()===""){ err.textContent = "Enter the COH."; left.focus(); return; }
      const payouts = [...rowsBox.querySelectorAll(".dcrow")].map(r=>({who:r.querySelector(".dcwho").value.trim(), amount:r.querySelector(".dcamt").value.trim()}))
        .filter(p=>p.who || p.amount);
      if (payouts.some(p=>!p.who)){ err.textContent = "Add who each payout went to."; return; }
      if (payouts.some(p=>!(Number(p.amount) > 0))){ err.textContent = "Enter an amount for each payout."; return; }
      ev.target.disabled = true; err.textContent = "";
      try {
        await call("api_daily_cash_save",{p_day:date.value, p_data:{cash_sales:sales.value, left_over:left.value, note:note.value, payouts}});
        if (prev && date.value!==day) await call("api_daily_cash_delete",{p_day:day});   // moved to another day
        play("ok"); closeSheet(); toast("Saved. The others get a notification."); await refresh(); scrollToDailyCash();
      } catch(x){ if (x.code==="not_logged_in") return logOut("You've been logged out. Enter your number again."); err.textContent = errMsg(x); ev.target.disabled = false; }
    }}, prev ? "Save changes" : "Save and send"),
    prev ? h("button",{type:"button", class:"linkbtn warn", style:"align-self:center", onclick:ev=>{
      if (ev.target.dataset.armed){ closeSheet(); act("api_daily_cash_delete",{p_day:day}, "Deleted "+shortDay(day)); }
      else { ev.target.dataset.armed = "1"; ev.target.textContent = "Tap again to delete this day"; } }},"Delete this day") : null,
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Cancel"));
  if (!prev) sales.focus();
}

/* ---------- cash-out at close ----------
   Toast counts the drawer and prints a Closed Drawer Report. If its Expected deposit has a minus sign (like −$6.22),
   the drawer is short by that much and a manager has to put it back. At close the bartender only says whether the
   drawer is short, and by how much. Managers get an alert, a list of drawers to replenish, and a history. */
const drawers = () => D().drawers || [];
const cashouts = () => D().cashouts || [];
const cents = n => Math.round(Number(n||0)*100)/100;
/* "$1,251.35", "$876" */
const cash = n => { const v = Math.abs(cents(n)); return "$"+v.toLocaleString("en-US",{minimumFractionDigits: v%1 ? 2 : 0, maximumFractionDigits:2}); };
const isShort = c => !!c && Number(c.short_amt) > 0;
const needsRefill = c => isShort(c) && !c.replenished_at;
const canCashOut = () => isAdmin() || (me().roles||[]).some(id=>(roleById(id)||{}).section==="foh");
/* the Drawers tab: managers always (to set it up); front of house once there's a drawer */
const showCashTab = () => !!me() && (isAdmin() || (canCashOut() && drawers().length > 0));
const cashFor = (day, drawerId) => cashouts().find(c=>c.day===day && c.drawer_id===drawerId);
const cashTag = c => isShort(c) ? h("span",{class:"tag "+(c.replenished_at ? "plain" : "danger"), text:"Short "+cash(c.short_amt)+(c.replenished_at ? " · replenished" : "")})
                                : h("span",{class:"tag ok", text:"Not short"});
const isLate = () => { const hr = new Date().getHours(); return hr >= 17 || hr < ROLL_HOUR; };

/* the chalkboard lines on the Tasks tab: tonight's cash-out from 5 PM (or once one's done), and for managers, drawers to replenish */
function cashBoardRows(today){
  const ds = drawers(), rows = []; if (!ds.length || !canCashOut()) return rows;
  const done = ds.map(d=>cashFor(today, d.id)).filter(Boolean), short = done.filter(isShort);
  const open = () => go("cash");
  if (isLate() || done.length){
    const v = short.length ? short.map(c=>c.drawer_name+" short "+cash(c.short_amt)).join(", ")
            : done.length===ds.length ? "Done ✓"
            : done.length ? done.length+" of "+ds.length+" done"
            : ds.length===1 ? "Not done yet" : ds.length+" drawers";
    rows.push(boardRow("tn-cash", "Cash-out", v, open, short.length>0 || (new Date().getHours() < ROLL_HOUR && done.length < ds.length)));
  }
  const owed = isAdmin() ? cashouts().filter(c=>needsRefill(c) && c.day!==today) : [];
  if (owed.length) rows.push(boardRow("tn-cash", "Replenish", owed.length===1 ? owed[0].drawer_name+" "+cash(owed[0].short_amt) : owed.length+" drawers · "+cash(owed.reduce((s,c)=>s+Number(c.short_amt),0)), open, true));
  return rows;
}
/* the tab's dot: in the evening until every drawer is done; for managers, while a drawer needs replenishing */
function cashDot(){
  const ds = drawers(); if (!S.data || !ds.length || !canCashOut()) return false;
  const today = shiftDay();
  return (isLate() && ds.some(d=>!cashFor(today, d.id))) || (isAdmin() && cashouts().some(needsRefill));
}

/* the cash-out: short or not, and how much */
function openCashOut(dr, day){
  day = day || shiftDay();
  const prev = cashFor(day, dr.id);
  let short = prev ? isShort(prev) : null;
  const amt = h("input",{type:"number", id:"coAmount", min:"0.01", step:"0.01", inputmode:"decimal", placeholder:"0.00", value: isShort(prev) ? prev.short_amt : ""});
  const amtBox = h("div",{class:"stack", style:"gap:6px"},
    h("label",{class:"lbl", for:"coAmount"}, "How much is it short? ($)", amt),
    h("p",{class:"hint", style:"margin:0", text:"The Expected deposit on the report, without the minus sign."}));
  const note = h("textarea",{id:"coNote", rows:"2", maxlength:"1000", placeholder:"Anything a manager should know"}, prev ? prev.note : "");
  const err = h("p",{class:"loginerr", role:"alert"});
  const pick = (val, label, sub) => h("label",{class:"yn"}, h("input",{type:"radio", name:"coShort", value:String(val), checked:short===val, onchange:()=>{ short = val; amtBox.hidden = !val; err.textContent = ""; if (val) amt.focus(); }}),
    h("span",{}, h("b",{text:label}), h("small",{text:sub})));
  amtBox.hidden = !short;
  openSheet(
    h("h2",{text:"Cash out: "+dr.name}),
    h("p",{class:"hint", style:"margin:-4px 0 0", text:(day!==shiftDay() ? "For "+longDay(day)+". " : "")+(prev ? "Entered by "+prev.by_name+" "+when(prev.at)+". Saving replaces it." : "Close the drawer in Toast and look at Expected deposit on the Closed Drawer Report. A minus sign (like −$6.22) means the drawer is short.")}),
    h("fieldset",{class:"choices"}, h("legend",{class:"lbl", text:"Is the drawer short?"}),
      h("div",{class:"ynpick"}, pick(false, "No", "Deposit is $0 or more"), pick(true, "Yes, it's short", "Deposit has a minus sign"))),
    amtBox,
    h("label",{class:"lbl", for:"coNote"}, "Note (optional)", note),
    err,
    h("button",{type:"button", class:"btn", onclick:async ev=>{
      if (short===null){ err.textContent = "Pick whether the drawer is short."; return; }
      const v = Number(amt.value);
      if (short && (!amt.value.trim() || isNaN(v) || v <= 0)){ err.textContent = "Enter how much it's short."; amt.focus(); return; }
      ev.target.disabled = true; err.textContent = "";
      try {
        const c = await call("api_cash_out",{p_drawer_id:dr.id, p_data:{short, amount: short ? cents(v) : 0, note:note.value}, p_day: day!==shiftDay() ? day : null});
        play(short ? "ok" : "cheers"); await refresh(); closeSheet();
        toast(short ? dr.name+" short "+cash(c.short_amt)+". Managers have been told." : dr.name+" cashed out ✓");
      } catch(x){ if (x.code==="not_logged_in") return logOut("You've been logged out. Enter your number again."); err.textContent = errMsg(x); ev.target.disabled = false; }
    }}, "Save"),
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Cancel"));
}

/* managers: one night */
function openCashDetail(c){
  openSheet(
    h("div",{class:"line"}, cashTag(c)),
    h("h2",{text:c.drawer_name+" · "+shortDay(c.day)}),
    h("div",{class:"pfacts"},
      partyFact("Short", isShort(c) ? cash(c.short_amt) : "No"),
      isShort(c) ? partyFact("Replenished", c.replenished_at ? when(c.replenished_at)+" by "+(c.replenished_by_name||"a manager") : "Not yet") : null,
      partyFact("Note", c.note)),
    h("p",{class:"hint", style:"margin:0", text:"Entered by "+(c.by_name||"someone")+" "+when(c.at)+(c.edits ? " · changed "+c.edits+(c.edits===1?" time":" times") : "")}),
    canWrite() && needsRefill(c) ? h("button",{type:"button", class:"btn", onclick:async()=>{ closeSheet(); await act("api_replenish",{p_id:c.id, p_done:true}, c.drawer_name+" replenished ✓"); }}, "Mark replenished") : null,
    canWrite() ? h("div",{class:"inline"},
      h("button",{type:"button", class:"btn ghost small", onclick:()=>openCashOut({id:c.drawer_id, name:c.drawer_name}, c.day)},"Change it"),
      c.replenished_at ? h("button",{type:"button", class:"btn ghost small", onclick:async()=>{ closeSheet(); await act("api_replenish",{p_id:c.id, p_done:false}, "Marked not replenished"); }},"Not replenished after all") : null,
      h("button",{type:"button", class:"linkbtn warn", onclick:ev=>{
        if (ev.target.dataset.armed){ closeSheet(); act("api_remove_cashout",{p_id:c.id}, "Cash-out deleted"); }
        else { ev.target.dataset.armed = "1"; ev.target.textContent = "Tap again to delete it"; } }},"Delete")) : null,
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Close"));
}

function openDrawerForm(d){
  const name = h("input",{type:"text", id:"drName", maxlength:"40", value:d ? d.name : "", placeholder:"Back Bar, Front Bar…", autocomplete:"off"});
  const err = h("p",{class:"loginerr", role:"alert"});
  openSheet(
    h("h2",{text:d ? "Rename drawer" : "Add a drawer"}),
    h("label",{class:"lbl", for:"drName"}, "Name", name),
    h("p",{class:"hint", style:"margin:0", text:"Use the name on Toast's report, like “Back Bar”, so it's easy to match."}),
    err,
    h("button",{type:"button", class:"btn", onclick:async ev=>{
      if (!name.value.trim()){ err.textContent = "Give the drawer a name."; name.focus(); return; }
      ev.target.disabled = true;
      if (await act("api_save_drawer",{p_id:d ? d.id : null, p_name:name.value.trim(), p_bank:Number(d ? d.bank : 0) || 0}, d ? "Drawer renamed" : name.value.trim()+" drawer added")) closeSheet();
      else ev.target.disabled = false;
    }}, d ? "Save" : "Add drawer"),
    d ? h("button",{type:"button", class:"linkbtn warn", style:"align-self:center", onclick:ev=>{
      if (ev.target.dataset.armed){ closeSheet(); act("api_remove_drawer",{p_id:d.id}, d.name+" drawer removed"); }
      else { ev.target.dataset.armed = "1"; ev.target.textContent = "Tap again to remove it (past nights stay)"; } }},"Remove this drawer") : null,
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Cancel"));
  name.focus();
}

function cashCsv(list){
  const q = v => { const s = String(v==null ? "" : v); return /[",\n]/.test(s) ? '"'+s.replace(/"/g,'""')+'"' : s; };
  const rows = [["Date","Drawer","Entered by","Short","Amount short","Replenished","Replenished by","Note"]];
  list.slice().sort((a,b)=>a.day.localeCompare(b.day)||a.drawer_name.localeCompare(b.drawer_name)).forEach(c=>rows.push([c.day, c.drawer_name, c.by_name,
    isShort(c) ? "Yes" : "No", isShort(c) ? c.short_amt : 0, c.replenished_at ? localDay(c.replenished_at) : "", c.replenished_by_name || "", c.note]));
  return rows.map(r=>r.map(q).join(",")).join("\n");
}
async function downloadCash(list){
  const name = "brewskis-cash-outs-"+shiftDay()+".csv";
  const file = new File([cashCsv(list)], name, {type:"text/csv"});
  try { if (navigator.canShare && navigator.canShare({files:[file]})){ await navigator.share({files:[file], title:"Cash-outs"}); return; } } catch(e){ if (e && e.name==="AbortError") return; }
  const a = h("a",{href:URL.createObjectURL(file), download:name}); document.body.append(a); a.click(); setTimeout(()=>{ URL.revokeObjectURL(a.href); a.remove(); }, 1000);
}

function cashRow(c, onclick){
  return h("button",{type:"button", class:"cashrow", onclick: onclick || (()=>openCashDetail(c))},
    h("span",{class:"t"}, h("b",{text:c.drawer_name}), h("span",{class:"hint", text:(c.by_name||"")+(c.note ? " · “"+c.note+"”" : "")})),
    cashTag(c));
}
function viewCash(){
  if (!showCashTab()){ S.view = "overview"; return viewOverview(); }
  const admin = isAdmin(), today = shiftDay(), ds = drawers(), out = [];
  out.push(h("div",{class:"sec-head"}, h("h2",{class:"sectitle", text:"Drawers"})));
  if (canCashBook()) out.push(dailyCashCard());
  if (!ds.length){
    out.push(admin
      ? emptyCard("Set up your drawers", "Add each cash drawer that gets closed out at night, using the name on Toast's report. Then whoever closes says here whether it came up short.",
          canWrite() ? h("button",{type:"button", class:"btn", onclick:()=>openDrawerForm(null)},"Add a drawer") : null)
      : emptyCard("No drawers yet", "Once a manager sets up the cash drawers, you'll cash them out here at close."));
    return out;
  }
  /* tonight */
  out.push(h("section",{class:"card stack cashtonight"},
    h("div",{class:"row"}, h("h3",{text:"Tonight"}), h("span",{class:"hint", text:shortDay(today)})),
    ds.map(d=>{ const c = cashFor(today, d.id);
      if (c) return admin ? cashRow(c) : cashRow(c, ()=>openCashOut(d));
      return h("div",{class:"cashrow todo"}, h("span",{class:"t"}, h("b",{text:d.name}), h("span",{class:"hint", text:"Not done yet"})),
        canWrite() ? h("button",{type:"button", class:"btn small"+(isLate() ? "" : " ghost"), onclick:()=>openCashOut(d)},"Cash out") : null); }),
    h("p",{class:"hint", style:"margin:0", text: admin ? "Tap one to see it, change it, or mark it replenished." : "After you close the drawer in Toast, check the Expected deposit on the report and enter it here. Tap one to change it."})));
  if (!admin) return out;
  /* drawers waiting on a manager */
  const owed = cashouts().filter(needsRefill).sort((a,b)=>a.day.localeCompare(b.day));
  if (owed.length) out.push(h("section",{class:"card stack refill"},
    h("div",{class:"row"}, h("h3",{text:"Needs replenishing"}), h("span",{class:"tag danger"}, roll("refill", cash(owed.reduce((s,c)=>s+Number(c.short_amt),0))))),
    owed.map(c=>h("div",{class:"cashrow"},
      h("button",{type:"button", class:"t linkish", onclick:()=>openCashDetail(c)}, h("b",{text:c.drawer_name+" · "+cash(c.short_amt)}), h("span",{class:"hint", text:shortDay(c.day)+" · "+(c.by_name||"")})),
      canWrite() ? h("button",{type:"button", class:"btn small", onclick:()=>act("api_replenish",{p_id:c.id, p_done:true}, c.drawer_name+" replenished ✓")},"Replenished") : null))));
  /* history */
  const range = S.cashRange || 30, from = addDays(today, -range);
  const list = cashouts().filter(c=>c.day < today && c.day >= from);
  const shorts = list.filter(isShort), total = shorts.reduce((s,c)=>s + Number(c.short_amt), 0);
  const sec = h("section",{class:"stack"},
    h("div",{class:"sec-head", style:"margin:0"}, h("h2",{text:"History"}),
      list.length ? h("button",{type:"button", class:"btn ghost small", onclick:()=>downloadCash(list)},"Download CSV") : null),
    h("div",{class:"chips", role:"group", "aria-label":"Time range"},
      [[7,"Last 7 days"],[30,"30 days"],[90,"90 days"]].map(([n,label])=>h("button",{type:"button", class:"chip", "aria-pressed":String(range===n), onclick:()=>{ S.cashRange = n; render(); }}, label))));
  if (!list.length) sec.append(h("p",{class:"hint", text:"Nothing before tonight in this range yet."}));
  else {
    sec.append(h("div",{class:"cashstats two"},
      h("div",{class:"cstat"+(shorts.length ? " neg" : "")}, h("small",{text:"Nights short"}), h("b",{}, roll("cash-nights", shorts.length)), h("small",{text:"of "+list.length+" cash-outs"})),
      h("div",{class:"cstat"+(total ? " neg" : "")}, h("small",{text:"Total short"}), h("b",{}, roll("cash-total", cash(total))), h("small",{text: shorts.length ? "about "+cash(total/shorts.length)+" a time" : "Nothing to put back"}))));
    const days = [...new Set(list.map(c=>c.day))].sort().reverse();
    sec.append(h("div",{class:"stack cashdays"}, days.map(day=>h("div",{class:"cashday"},
      h("div",{class:"divider", text:shortDay(day)}),
      list.filter(c=>c.day===day).sort((a,b)=>a.drawer_name.localeCompare(b.drawer_name)).map(c=>cashRow(c)),
      ds.filter(d=>!list.some(c=>c.day===day && c.drawer_id===d.id)).map(d=>h("div",{class:"cashrow todo"}, h("span",{class:"t"}, h("b",{text:d.name}), h("span",{class:"hint", text:"Nothing entered"})),
        canWrite() ? h("button",{type:"button", class:"btn ghost small", onclick:()=>openCashOut(d, day)},"Add") : null))))));
  }
  out.push(sec);
  /* setup */
  out.push(h("section",{class:"stack"},
    h("h3",{class:"sethead", text:"Setup"}),
    ds.map(d=>setRow(d.name, "Tap to rename or remove", "", ()=>openDrawerForm(d))),
    canWrite() ? h("button",{type:"button", class:"btn ghost small", style:"align-self:flex-start", onclick:()=>openDrawerForm(null)},"+ Add a drawer") : null));
  return out;
}
