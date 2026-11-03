/* JT Brewski's staff app · Party bookings: inquiries, holds, deposits and the party sheet. */
"use strict";

/* ---------- party bookings ----------
   Inquiries come in from the website's Google Form (or a manager adds a booking taken by phone).
   inquiry -> hold (date held, waiting on the deposit) -> booked (deposit paid); or declined / cancelled.
   Held and booked parties are Party events on the calendar. Staff see them without contact details or money. */
const PARTY_PKGS = [["open_bar_food","Open bar + food"],["open_bar","Open bar only"],["cash_bar","Cash bar"],["space","Just the space"]];
const pkgLabel = k => (PARTY_PKGS.find(x=>x[0]===k)||[])[1] || "";
const PARTY_STATUS = {inquiry:["New inquiry","warn"], hold:["On hold","plain"], booked:["Booked","ok"], declined:["Declined","plain"], cancelled:["Cancelled","plain"]};
const OCCASIONS = ["Birthday","Graduation","Corporate","Holiday Party","Retirement","Anniversary","Engagement","Shower","Reunion","Celebration of life"];
const DEPOSIT_HOW = ["Cash","Card","Check","Venmo","Zelle","Other"];
const parties = () => D().parties || [];
const partyById = id => parties().find(p=>p.id===id);
const partyOfEvent = e => e && e.kind==="party" ? parties().find(p=>p.event_id===e.id) : null;
function partyWho(p){ const w = (p.host_name||"").trim().split(/\s+/).filter(Boolean); if (!w.length) return "Guest"; const cap = s => s[0].toUpperCase()+s.slice(1); return w.length===1 ? cap(w[0]) : cap(w[0])+" "+w[w.length-1][0].toUpperCase()+"."; }
const partyFirst = p => ((p.host_name||"").trim().split(/\s+/)[0] || "there");
const partyTitle = p => partyWho(p) + (p.occasion ? " · "+p.occasion : "'s party");
const money = n => n==null || n==="" || isNaN(Number(n)) ? "" : "$"+(Number(n)%1 ? Number(n).toFixed(2) : String(Number(n)));
const depositSetting = () => { const v = (D().settings||{}).party_deposit; return v==null || v==="" ? null : Number(v); };
const partyGuests = p => p.guests ? (p.status==="inquiry" ? "~" : "")+p.guests+" guests" : p.guests_text ? p.guests_text+" guests" : "";
/* other held or booked parties that day */
const partyClash = (p, day) => !day ? [] : parties().filter(x=>x.id!==p.id && x.day===day && (x.status==="hold" || x.status==="booked"));

function partyRow(p){
  const d = p.day ? parseDay(p.day) : null, st = PARTY_STATUS[p.status] || ["",""];
  const clash = p.status!=="declined" && p.status!=="cancelled" && partyClash(p, p.day).length;
  return h("button",{type:"button", class:"evrow ev-party prow", onclick:()=>openPartySheet(p)},
    h("span",{class:"evdate", "aria-hidden":"true"},
      d ? [h("small",{text:d.toLocaleDateString(undefined,{weekday:"short"})}), h("b",{text:String(d.getDate())}), h("small",{text:d.toLocaleDateString(undefined,{month:"short"})})] : h("b",{text:"?"})),
    h("span",{class:"evbody"},
      h("span",{class:"evname", text:partyTitle(p)}),
      h("span",{class:"line"}, h("span",{class:"tag "+st[1], text:st[0]}),
        partyGuests(p) ? h("span",{class:"hint", text:partyGuests(p)}) : null,
        clash ? h("span",{class:"tag warn", text:"Another party that day"}) : null),
      p.status==="inquiry" ? h("span",{class:"hint evnote", text:"Sent "+when(p.submitted_at)+(p.backup_day ? " · back-up "+shortDay(p.backup_day) : "")}) : null));
}
/* managers: the top of the Events tab */
function partiesCard(){
  const today = shiftDay();
  const inq = parties().filter(p=>p.status==="inquiry").sort((a,b)=>String(a.submitted_at).localeCompare(String(b.submitted_at)));
  const holds = parties().filter(p=>p.status==="hold" && p.day >= today).sort((a,b)=>a.day.localeCompare(b.day));
  const booked = parties().filter(p=>p.status==="booked" && p.day >= today);
  return h("section",{class:"card partycard stack"},
    h("div",{class:"row"}, h("h2",{text:"Party bookings"}),
      inq.length ? h("span",{class:"tag warn", text:inq.length+(inq.length===1 ? " new inquiry" : " new inquiries")})
                 : booked.length ? h("span",{class:"tag plain", text:booked.length+" booked"}) : null),
    inq.length ? h("div",{class:"evlist"}, inq.map(partyRow))
               : h("p",{class:"hint", style:"margin:0", text: holds.length ? "No inquiries waiting." : "No inquiries waiting. New ones from your website's party form show up here, and managers get an alert."}),
    holds.length ? h("div",{class:"stack", style:"gap:8px"}, h("b",{class:"subhead", text:"On hold · waiting on a deposit"}), h("div",{class:"evlist"}, holds.map(partyRow))) : null,
    canWrite() ? h("button",{type:"button", class:"btn ghost small", style:"align-self:flex-start", onclick:()=>openPartyForm(null)},"+ Add a booking") : null);
}

function partyFact(label, value){ return value ? h("div",{class:"pfact"}, h("span",{class:"hint", text:label}), h("span",{text:value})) : null; }
function partyReplyMail(p){
  const day = p.day ? longDay(p.day) : "your date";
  return "mailto:"+encodeURIComponent(p.email)+"?subject="+encodeURIComponent("Your party at JT Brewski's")+"&body="+encodeURIComponent(
    "Hi "+partyFirst(p)+",\n\nThanks for reaching out about "+(p.occasion ? "your "+p.occasion.toLowerCase()+" party" : "a party")+" on "+day+". \n\n\nJT Brewski's Pub");
}
function dateCheck(p, day, label){
  const c = partyClash(p, day), past = day < shiftDay();
  return h("div",{class:"row datecheck"}, h("span",{}, h("span",{class:"hint", text:label+" "}), h("b",{text:shortDay(day)})),
    past ? h("span",{class:"tag plain", text:"Passed"})
         : c.length ? h("span",{class:"tag warn", text:"Taken: "+partyTitle(c[0])+(c[0].status==="hold" ? " (on hold)" : "")})
         : h("span",{class:"tag ok", text:"Free"}));
}
function openPartySheet(p){
  if (!p) return;
  const admin = isAdmin(), today = shiftDay(), st = PARTY_STATUS[p.status] || ["",""];
  const reopen = () => { const f = partyById(p.id); if (f && !$("sheet").hidden) openPartySheet(f); };
  const kids = [
    h("div",{class:"line"}, kindTag("party"), h("span",{class:"tag "+st[1], text:st[0]}),
      p.day && p.day >= today && eventWhen(p) ? h("span",{class:"hint", text:eventWhen(p)}) : null),
    h("h2",{class:"evsheet-title", text: admin ? (p.host_name || "Guest") : partyTitle(p)}),
    admin && p.occasion ? h("p",{class:"psub", text:p.occasion}) : null,
    h("div",{class:"evsheet-when"}, h("b",{text:p.day ? longDay(p.day) : "No date yet"}), eventTime(p) ? h("span",{text:eventTime(p)}) : null),
    h("div",{class:"pfacts"},
      partyFact("Guests", partyGuests(p) || (admin ? "Not given" : "")),
      partyFact("Package", pkgLabel(p.package) || (admin ? "Not picked" : "")),
      partyFact("Requests", p.notes))];
  if (!admin){
    kids.push(h("p",{class:"hint", style:"margin:0", text: p.status==="hold" ? "This date is on hold. It isn't final until the deposit is in." : "Questions about this party? Ask a manager."}));
    kids.push(h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Close"));
    return openSheet(...kids);
  }
  /* managers */
  if (p.status==="inquiry"){
    kids.push(h("div",{class:"stack datechecks"}, p.day ? dateCheck(p, p.day, "Wants") : null, p.backup_day ? dateCheck(p, p.backup_day, "Back-up") : null));
  } else if ((p.status==="hold" || p.status==="booked") && partyClash(p, p.day).length){
    kids.push(h("p",{class:"tag warn", style:"align-self:flex-start", text:"Also that day: "+partyClash(p, p.day).map(partyTitle).join(", ")}));
  }
  if (p.phone || p.email) kids.push(h("div",{class:"inline contact"},
    p.phone ? h("a",{class:"btn ghost small", href:"tel:"+p.phone.replace(/[^\d+]/g,"")}, "Call") : null,
    p.phone ? h("a",{class:"btn ghost small", href:"sms:"+p.phone.replace(/[^\d+]/g,"")}, "Text") : null,
    p.email ? h("a",{class:"btn ghost small", href: p.status==="inquiry" ? partyReplyMail(p) : "mailto:"+encodeURIComponent(p.email)}, "Email") : null));
  kids.push(h("div",{class:"pfacts"},
    partyFact("Phone", p.phone), partyFact("Email", p.email),
    partyFact("Deposit", p.deposit_paid_on ? money(p.deposit)+" paid "+shortDay(p.deposit_paid_on)+(p.deposit_how ? " · "+p.deposit_how : "")
                         : p.status==="hold" || p.status==="inquiry" ? ((money(p.deposit ?? depositSetting()) || "Deposit")+" not paid yet") : ""),
    partyFact("Manager notes", p.private_notes)));
  kids.push(h("p",{class:"hint", style:"margin:0", text: p.source==="form" ? "Sent "+when(p.submitted_at)+" from the website form"+(p.decided_by_name && p.status!=="inquiry" ? " · "+st[0].toLowerCase()+" by "+p.decided_by_name : "")
                                                        : "Added by "+(p.added_by_name || "a manager")}));
  if (canWrite()){
    const arm = (label, armed, fn) => h("button",{type:"button", class:"linkbtn warn", onclick:ev=>{
      if (ev.target.dataset.armed){ closeSheet(); fn(); } else { ev.target.dataset.armed = "1"; ev.target.textContent = armed; } }}, label);
    const setStatus = (status, day, msg) => async () => { if (await act("api_party_status",{p_id:p.id, p_status:status, p_day:day||null}, msg)) reopen(); };
    if (p.status==="inquiry"){
      const days = [p.day, p.backup_day].filter(d=>d && d >= today);
      days.forEach((d, i)=>kids.push(h("button",{type:"button", class:"btn"+(i ? " ghost" : ""), onclick:setStatus("hold", d, "Holding "+shortDay(d)+" for "+partyWho(p)+". It's on the calendar.")}, "Hold "+shortDay(d))));
      kids.push(h("button",{type:"button", class:"btn ghost", onclick:()=>openDepositForm(p)}, "Deposit's in: book it"));
      kids.push(h("div",{class:"inline"},
        h("button",{type:"button", class:"btn ghost small", onclick:()=>{ closeSheet(); openPartyForm(p); }},"Edit details"),
        arm("Decline", "Tap again to decline", ()=>act("api_party_status",{p_id:p.id, p_status:"declined"}, "Inquiry declined"))));
    } else if (p.status==="hold" || p.status==="booked"){
      if (p.status==="hold") kids.push(h("button",{type:"button", class:"btn", onclick:()=>openDepositForm(p)}, "Deposit paid"));
      kids.push(h("div",{class:"inline"},
        h("button",{type:"button", class:"btn ghost small", onclick:()=>{ closeSheet(); openPartyForm(p); }},"Edit details"),
        arm("Cancel booking", "Tap again to cancel it", ()=>act("api_party_status",{p_id:p.id, p_status:"cancelled"}, "Booking cancelled. It's off the calendar."))));
    } else {
      kids.push(h("button",{type:"button", class:"btn ghost", onclick:setStatus("inquiry", null, "Reopened as an inquiry")}, "Reopen as an inquiry"));
    }
  }
  kids.push(h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Close"));
  openSheet(...kids);
}

function openDepositForm(p){
  let how = p.deposit_how || "";
  const amt = h("input",{type:"number", id:"depAmount", inputmode:"decimal", min:"0", step:"1", value: p.deposit ?? depositSetting() ?? ""});
  const day = h("input",{type:"date", id:"depDay", value:shiftDay(), max:shiftDay()});
  const seg = h("div",{class:"kindpick howpick plainpick", role:"radiogroup", "aria-label":"Paid by"},
    DEPOSIT_HOW.map(x=>h("label",{class:"kindopt"}, h("input",{type:"radio", name:"depHow", value:x, checked:how===x, onchange:()=>{ how = x; }}), h("span",{text:x}))));
  const err = h("p",{class:"loginerr", role:"alert"});
  openSheet(
    h("h2",{text:"Deposit for "+partyWho(p)}),
    h("p",{class:"hint", style:"margin:0", text:"Books the party for "+(p.day ? longDay(p.day) : "their date")+"."}),
    h("label",{class:"lbl", for:"depAmount"}, "Amount ($)", amt),
    h("fieldset",{class:"choices"}, h("legend",{class:"lbl", text:"Paid by (optional)"}), seg),
    h("label",{class:"lbl", for:"depDay"}, "Paid on", day),
    err,
    h("button",{type:"button", class:"btn", onclick:async ev=>{
      const v = amt.value.trim();
      if (v==="" || isNaN(Number(v)) || Number(v) < 0){ err.textContent = "Enter the deposit amount."; amt.focus(); return; }
      ev.target.disabled = true; err.textContent = "";
      try {
        await call("api_party_deposit",{p_id:p.id, p_amount:Number(v), p_paid_on:day.value||null, p_how:how});
        play("cheers"); toast(partyWho(p)+" is booked 🎉"); await refresh();
        const f = partyById(p.id); if (f) openPartySheet(f); else closeSheet();
      } catch(x){ if (x.code==="not_logged_in") return logOut("You've been logged out. Enter your number again."); err.textContent = errMsg(x); ev.target.disabled = false; }
    }}, "Save and book it"),
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Cancel"));
  amt.focus();
}

/* managers: add a booking (taken by phone or in person) or change one */
function openPartyForm(p){
  const today = shiftDay();
  const f = (id, type, val, extra) => h("input", Object.assign({type, id, value:val ?? ""}, extra||{}));
  const name = f("ptName","text", p && p.host_name, {maxlength:"80", autocomplete:"off", placeholder:"Who's booking it"});
  const phone = f("ptPhone","tel", p && p.phone, {maxlength:"40", autocomplete:"off"});
  const email = f("ptEmail","email", p && p.email, {maxlength:"120", autocomplete:"off"});
  const occ = f("ptOcc","text", p && p.occasion, {maxlength:"60", list:"ptOccList", placeholder:"Birthday, graduation…"});
  const day = f("ptDay","date", p ? p.day : "", {min: p ? undefined : today});
  const backup = f("ptBackup","date", p && p.backup_day);
  const st = f("ptStart","time", p ? hhmm(p.start_time) : "");
  const en = f("ptEnd","time", p ? hhmm(p.end_time) : "");
  const guests = f("ptGuests","number", p && p.guests, {min:"1", max:"5000", inputmode:"numeric"});
  const pkg = h("select",{id:"ptPkg"}, h("option",{value:""},"Not picked yet"), PARTY_PKGS.map(([id,label])=>h("option",{value:id, selected:!!p && p.package===id}, label)));
  const notes = h("textarea",{id:"ptNotes", rows:"3", maxlength:"2000", placeholder:"Cake, decorations, a game on the TV, food allergies…"}, p ? p.notes : "");
  const priv = h("textarea",{id:"ptPriv", rows:"2", maxlength:"2000", placeholder:"Only managers see this"}, p ? p.private_notes : "");
  const dep = f("ptDeposit","number", p ? (p.deposit ?? (p.deposit_paid_on ? "" : depositSetting())) : depositSetting(), {min:"0", step:"1", inputmode:"decimal"});
  let status = "hold";
  const statusPick = p ? null : h("fieldset",{class:"choices"}, h("legend",{class:"lbl", text:"Status"}),
    h("div",{class:"kindpick plainpick"}, [["hold","On hold · waiting on the deposit"],["booked","Booked · deposit's paid"]].map(([id,label])=>
      h("label",{class:"kindopt"}, h("input",{type:"radio", name:"ptStatus", value:id, checked:status===id, onchange:()=>{ status = id; }}), h("span",{text:label})))));
  const clash = h("p",{class:"hint warnline", role:"status"});
  const sync = () => { const c = day.value ? partyClash(p || {id:null}, day.value) : []; clash.textContent = c.length ? "Heads up: "+c.map(partyTitle).join(", ")+" "+(c.length===1?"is":"are")+" already that day." : ""; clash.hidden = !c.length; };
  day.addEventListener("change", sync); day.addEventListener("input", sync); sync();
  const err = h("p",{class:"loginerr", role:"alert"});
  openSheet(
    h("h2",{text:p ? "Edit party" : "Add a party booking"}),
    h("datalist",{id:"ptOccList"}, OCCASIONS.map(o=>h("option",{value:o}))),
    h("label",{class:"lbl", for:"ptName"}, "Name", name),
    h("div",{class:"inline"}, h("label",{class:"lbl", for:"ptPhone", style:"flex:1"}, "Phone", phone), h("label",{class:"lbl", for:"ptEmail", style:"flex:1"}, "Email", email)),
    h("label",{class:"lbl", for:"ptOcc"}, "Occasion", occ),
    h("div",{class:"inline"}, h("label",{class:"lbl", for:"ptDay", style:"flex:1"}, "Date", day), h("label",{class:"lbl", for:"ptBackup", style:"flex:1"}, "Back-up date", backup)),
    clash,
    h("div",{class:"inline"}, h("label",{class:"lbl", for:"ptStart", style:"flex:1"}, "Starts", st), h("label",{class:"lbl", for:"ptEnd", style:"flex:1"}, "Ends", en)),
    h("div",{class:"inline"}, h("label",{class:"lbl", for:"ptGuests", style:"flex:1"}, "Guests", guests), h("label",{class:"lbl", for:"ptPkg", style:"flex:2"}, "Package", pkg)),
    h("label",{class:"lbl", for:"ptNotes"}, "Requests (staff see these)", notes),
    h("label",{class:"lbl", for:"ptPriv"}, "Manager notes", priv),
    h("label",{class:"lbl", for:"ptDeposit"}, "Deposit ($)", dep),
    statusPick,
    err,
    h("button",{type:"button", class:"btn", onclick:async ev=>{
      if (!name.value.trim()){ err.textContent = "Add the name of who's booking it."; name.focus(); return; }
      if (!day.value){ err.textContent = "Pick the date."; return; }
      ev.target.disabled = true; err.textContent = "";
      const data = {host_name:name.value, phone:phone.value, email:email.value, occasion:occ.value, day:day.value, backup_day:backup.value||null,
                    start_time:st.value||null, end_time:en.value||null, guests:guests.value||null, package:pkg.value, notes:notes.value,
                    private_notes:priv.value, deposit:dep.value===""?null:dep.value};
      if (!p) data.status = status;
      try {
        const id = await call("api_save_party",{p_id:p ? p.id : null, p_data:data});
        play("ok"); toast(p ? "Party saved" : status==="booked" ? "Booked 🎉 It's on the calendar." : "On hold. It's on the calendar.");
        S.evMonth = day.value.slice(0,7); S.evDay = null;
        await refresh();
        const fresh = partyById(id); if (fresh) openPartySheet(fresh); else closeSheet();
      } catch(x){ if (x.code==="not_logged_in") return logOut("You've been logged out. Enter your number again."); err.textContent = errMsg(x); ev.target.disabled = false; }
    }}, p ? "Save" : "Add booking"),
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Cancel"));
  if (!p) name.focus();
}

/* Settings: the usual deposit */
function openDepositSetting(){
  const v = h("input",{type:"number", id:"setDeposit", min:"0", step:"1", inputmode:"decimal", value:depositSetting() ?? ""});
  const err = h("p",{class:"loginerr", role:"alert"});
  openSheet(
    h("h2",{text:"Party deposit"}),
    h("p",{class:"hint", style:"margin:0", text:"The usual amount to lock in a party date. It's filled in for you when you book a party, and you can change it for any one party."}),
    h("label",{class:"lbl", for:"setDeposit"}, "Amount ($)", v),
    err,
    h("button",{type:"button", class:"btn", onclick:async ev=>{
      const s = v.value.trim();
      if (s!=="" && (isNaN(Number(s)) || Number(s) < 0)){ err.textContent = "Enter an amount, or leave it blank."; return; }
      ev.target.disabled = true;
      if (await act("api_set_setting",{p_name:"party_deposit", p_value: s==="" ? null : Number(s)}, s==="" ? "Deposit cleared" : "Deposit set to "+money(s))) closeSheet();
      else ev.target.disabled = false;
    }}, "Save"),
    h("button",{type:"button", class:"btn ghost", onclick:closeSheet},"Cancel"));
  v.focus();
}
