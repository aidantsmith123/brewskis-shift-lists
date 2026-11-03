/* JT Brewski's staff app · Settings > Team: people, roles and login numbers. */
"use strict";

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
      (behind ? "Phones update themselves the next time the app is opened. Check-ins show up then too." : "")}));
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
    h("button",{type:"button", class:"back", onclick:()=>go("settings")},"← Settings"),
    h("div",{class:"sec-head"}, h("h2",{text:"Team"}), h("span",{class:"hint", text:d.staff.length+" "+(d.staff.length===1?"person":"people")})),
    versionSummary(),
    h("button",{type:"button", class:"btn ghost invitebtn", onclick:openInviteSheet}, "Invite people: link, texts and a sign-up poster"),
    h("p",{class:"hint", text:"Everyone logs in with the number you assign here. Only people with the Manager role get manager controls: this Team page, inventory pars and suppliers, order deadlines, and starter lists."}),
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
