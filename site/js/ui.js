/* JT Brewski's staff app · Sound effects, motion and other shared bits of the interface. */
"use strict";

/* ---------- shared bits ---------- */
function progressOf(tasks){ const done = tasks.filter(isDone).length; return {done, total:tasks.length, pct: tasks.length ? Math.round(done/tasks.length*100) : 0}; }
/* today's progress as a stein from the logo: beer rises with the share of tasks done */
/* ---------- sound effects ----------
   Made on the fly with Web Audio, no sound files. Each phone can turn them off (tap your name).
   On iPhone they follow the ring/silent switch; on Android, media volume. Android also gets a short vibration. */
let soundOn = (()=>{ try { return localStorage.getItem("brewskis.sound") !== "off"; } catch(e){ return true; } })();
let actx = null;
function audio(){
  if (!actx){
    const AC = window.AudioContext || window.webkitAudioContext; if (!AC) return null;
    try { if (navigator.audioSession) navigator.audioSession.type = "ambient"; } catch(e){}   // respect silent mode, don't stop other audio
    actx = new AC();
  }
  if (actx.state==="suspended") actx.resume().catch(()=>{});
  return actx;
}
function tone(ctx, dest, t, o){
  const osc = ctx.createOscillator(), g = ctx.createGain(), dur = o.dur || 0.2;
  osc.type = o.type || "sine";
  osc.frequency.setValueAtTime(o.freq, t);
  if (o.to) osc.frequency.exponentialRampToValueAtTime(o.to, t + dur);
  g.gain.setValueAtTime(0.0001, t);
  g.gain.exponentialRampToValueAtTime(o.gain || 0.2, t + (o.attack || 0.004));
  g.gain.exponentialRampToValueAtTime(0.0001, t + dur);
  osc.connect(g); g.connect(dest); osc.start(t); osc.stop(t + dur + 0.03);
}
const SOUNDS = {
  /* checking off a task: two glasses touching */
  clink(ctx, d, t){
    [[2093,.20,.55],[3135,.10,.38],[4186,.05,.22]].forEach(([f,g,dur])=>tone(ctx,d,t,{freq:f,gain:g,dur}));
    [[2489,.14,.45],[3729,.07,.30]].forEach(([f,g,dur])=>tone(ctx,d,t+.065,{freq:f,gain:g,dur}));
  },
  /* last task on a role's list for today: a rising chime, then the clink */
  cheers(ctx, d, t){
    [784,988,1319].forEach((f,i)=>{ tone(ctx,d,t+i*.09,{freq:f,type:"triangle",gain:.18,dur:.38}); tone(ctx,d,t+i*.09,{freq:f*2,gain:.05,dur:.25}); });
    SOUNDS.clink(ctx, d, t+.3);
  },
  /* intro: a light woosh that rises with the pour (noise swept up through a filter) */
  woosh(ctx, d, t, len){
    len = len || .9;
    const n = Math.ceil(ctx.sampleRate*len), buf = ctx.createBuffer(1, n, ctx.sampleRate), ch = buf.getChannelData(0);
    for (let i=0;i<n;i++) ch[i] = Math.random()*2 - 1;
    const src = ctx.createBufferSource(); src.buffer = buf;
    const bp = ctx.createBiquadFilter(); bp.type = "bandpass"; bp.Q.value = .8;
    bp.frequency.setValueAtTime(260, t); bp.frequency.exponentialRampToValueAtTime(2400, t+len*.72); bp.frequency.exponentialRampToValueAtTime(1500, t+len);
    const g = ctx.createGain();
    g.gain.setValueAtTime(.0001, t); g.gain.exponentialRampToValueAtTime(.28, t+len*.6); g.gain.exponentialRampToValueAtTime(.0001, t+len);
    src.connect(bp); bp.connect(g); g.connect(d); src.start(t); src.stop(t+len+.02);
  },
  wooshQuick(ctx, d, t){ SOUNDS.woosh(ctx, d, t, .45); },
  /* any other button: a short, soft wooden tap */
  tap(ctx, d, t){ tone(ctx,d,t,{freq:760,to:540,type:"sine",gain:.11,dur:.032,attack:.002}); tone(ctx,d,t,{freq:2300,type:"sine",gain:.025,dur:.012,attack:.001}); },
  /* unchecking: a soft falling tock */
  undo(ctx, d, t){ tone(ctx,d,t,{freq:520,to:330,type:"triangle",gain:.16,dur:.14}); },
  /* counting: tiny ticks, higher for +, lower for − */
  tickUp(ctx, d, t){ tone(ctx,d,t,{freq:1500,type:"triangle",gain:.12,dur:.045}); },
  tickDown(ctx, d, t){ tone(ctx,d,t,{freq:1000,type:"triangle",gain:.12,dur:.045}); },
  /* logged in, order placed: two notes up */
  ok(ctx, d, t){ tone(ctx,d,t,{freq:660,type:"triangle",gain:.17,dur:.12}); tone(ctx,d,t+.1,{freq:990,type:"triangle",gain:.17,dur:.24}); },
  /* wrong number, couldn't save: two low notes down */
  nope(ctx, d, t){ tone(ctx,d,t,{freq:233,type:"square",gain:.05,dur:.11}); tone(ctx,d,t+.14,{freq:185,type:"square",gain:.05,dur:.16}); }
};
const BUZZ = {clink:12, cheers:[15,60,30], ok:10, nope:[40,60,40]};
function play(name){
  if (!soundOn) return;
  try { const ctx = audio(); if (ctx) SOUNDS[name](ctx, ctx.destination, ctx.currentTime + .01); } catch(e){}
  try { if (BUZZ[name] && navigator.vibrate) navigator.vibrate(BUZZ[name]); } catch(e){}
}
/* every button tap gets the soft tap, unless that button plays its own sound */
document.addEventListener("click", e=>{
  const el = e.target.closest && e.target.closest("button, select, [role=button], a[href]");
  if (!el || el.disabled || el.hasAttribute("data-own-sound")) return;
  play("tap");
}, true);
function setSound(on){
  soundOn = on;
  try { localStorage.setItem("brewskis.sound", on ? "on" : "off"); } catch(e){}
  if (on) play("clink");
}

/* ---------- motion ----------
   Bars and the stein remember the last value they showed and slide to the new one, so checking off a task
   visibly fills them. The stein pours from empty the first time it's shown after the app opens. */
const lastShown = new Map();
function growFrom(key, pct, firstFrom){
  const to = Math.max(0, Math.min(100, pct));
  const from = lastShown.has(key) ? lastShown.get(key) : firstFrom;
  lastShown.set(key, to);
  return {from: from==null ? to : from, to};
}
function stein(pct){
  const g = growFrom("stein", pct, 0);
  return h("div",{class:"stein", "aria-hidden":"true"},
    h("div",{class:"stein-glass"},
      h("div",{class:"stein-beer"+(pct>0?" has-foam":""), style:"height:"+g.from+"%", "data-grow-h":g.to}),
      h("div",{class:"stein-hoops"})));
}
function bar(pct, key){
  const g = key ? growFrom(key, pct) : {from:pct, to:pct};
  return h("div",{class:"bar", role:"progressbar", "aria-valuenow":pct, "aria-valuemin":0, "aria-valuemax":100},
    h("i",{style:"width:"+g.from+"%", "data-grow-w":g.to}));
}
/* after each render: slide bars to their new values, and fade in a newly opened screen */
let lastScreen = null;
function afterRender(){
  const els = document.querySelectorAll("[data-grow-w],[data-grow-h]");
  if (els.length){
    els[0].getBoundingClientRect();   // lock in the starting size so the change animates
    requestAnimationFrame(()=>els.forEach(el=>{
      if (el.dataset.growW!=null) el.style.width = el.dataset.growW+"%";
      if (el.dataset.growH!=null) el.style.height = el.dataset.growH+"%";
    }));
  }
  const screen = !S.session ? "login" : S.view + (S.view==="role" ? ":"+S.roleId : "");
  if (screen !== lastScreen){
    const main = $("view");
    if (lastScreen !== null){ main.classList.remove("enter"); void main.offsetWidth; main.classList.add("enter"); }
    lastScreen = screen;
  }
  S.fx = {};   // one-shot effects only play on the render that triggered them
}
/* grey placeholder shapes while something loads */
function skeleton(kind){
  const b = (cls, style) => h("div",{class:"skel "+(cls||""), style:style||"", "aria-hidden":"true"});
  const busy = h("p",{class:"sr-only", role:"status", text:"Loading…"});
  if (kind==="home") return [busy, b("skel-hero"), b("", "height:22px;width:38%"), h("div",{class:"stack"}, [0,1,2,3].map(()=>b("skel-row")))];
  if (kind==="week") return [busy, h("div",{class:"stack"}, [0,1,2].map(()=>b("skel-day")))];
  return [busy, h("div",{class:"stack"}, [0,1,2].map(()=>b("skel-row")))];
}
function emptyCard(title, body, ...actions){ actions = actions.filter(Boolean); return h("div",{class:"empty"}, h("h2",{text:title}), h("p",{text:body}), actions.length ? h("div",{class:"inline"}, actions) : null); }
function svgCheck(){ const s = document.createElementNS("http://www.w3.org/2000/svg","svg"); s.setAttribute("viewBox","0 0 24 24"); s.innerHTML = '<path d="M5 12.5l4.5 4.5L19 7.5" fill="none" stroke="currentColor" stroke-width="3" stroke-linecap="round" stroke-linejoin="round" style="color:var(--card)"/>'; return s; }
const doneName = t => t.done_by_name || staffName(t.done_by);
const addedName = t => t.added_by_name || (t.added_by ? staffName(t.added_by) : "Someone");
