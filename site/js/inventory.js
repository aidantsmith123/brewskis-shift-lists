/* JT Brewski's staff app · The Inventory tab: counts, pars, suppliers, order deadlines and the on tap board. */
"use strict";

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
  return h("div",{class:"item"+(it.on_tap?" pouring":"")+(flashing("item:"+it.id) ? " live-flash" : ""), "data-item":it.id},
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
    h("div",{class:"sec-head", style:"margin:0"}, h("h2",{class:"ptitle", text:"Inventory"}),
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
    const badge = toPlace ? h("span",{class:"tag warn"}, roll("toplace", toPlace), toPlace===1?" order to place":" orders to place")
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
                : low ? h("span",{class:"tag warn"}, roll("low:"+cat.id, low), " below par")
                : pouring ? h("span",{class:"tag ok"}, roll("tap:"+cat.id, pouring), " on tap")
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
