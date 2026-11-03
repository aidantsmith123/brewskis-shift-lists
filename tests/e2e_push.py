"""Notification settings: turning them on (with a stand-in push service), changing what you get, settings
coming back after a reload, turning them off; and who sees which switches. Run on setup_v22.sh.
(Sending a real test notification needs the live Edge Function, so it isn't covered here.)"""
import sys, json, subprocess
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
def sql(q): return subprocess.run(["psql","-h","/var/tmp","-p","54329","-U","postgres","-d","bk","-Atc",q],capture_output=True,text=True,check=True).stdout.strip()
sql("select admin_set_pin('Mandy','7777'); select admin_set_pin('Brian','3333')")
MOCK = """
window.__perm = sessionStorage.getItem("perm") || "default";
Object.defineProperty(Notification, "permission", {get: ()=>window.__perm});
Notification.requestPermission = async ()=> { sessionStorage.setItem("perm","granted"); return (window.__perm = "granted"); };
const fake = {endpoint:"https://fcm.googleapis.com/fcm/send/test-device-"+(sessionStorage.getItem("who")||"x"),
  toJSON(){ return {endpoint:this.endpoint, keys:{p256dh:"BNcRdreALRFXTkOOUHK1EtK2wtaz5Ry4YfYCA_0QTpQtUbVlUls0VJXg7A8u-Ts1XbjhazAkj7I99e8QcYP7DkM", auth:"tBHItJI5svbpez7KI4CCXg"}}; },
  unsubscribe: async ()=>{ sessionStorage.removeItem("sub"); return true; }};
if (window.PushManager){ PushManager.prototype.getSubscription = async function(){ return sessionStorage.getItem("sub") ? fake : null; };
  PushManager.prototype.subscribe = async function(){ sessionStorage.setItem("sub","1"); return fake; }; }
"""
def login(b, pin, who):
    ctx=b.new_context(viewport={"width":390,"height":844}, timezone_id="America/New_York")
    ctx.grant_permissions(["notifications"], origin="http://127.0.0.1:8099")
    ctx.add_init_script("sessionStorage.setItem('who','%s');" % who); ctx.add_init_script(MOCK)
    pg=ctx.new_page(); pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1200)
    pg.locator("#settingsBtn").click(); pg.get_by_role("button", name="Notifications").click(); pg.wait_for_timeout(600)
    return pg
def switches(pg): return pg.locator(".prefrow b").all_inner_texts()
with sync_playwright() as p:
    b=p.chromium.launch(); errs=[]
    a=login(b,"4821","aidan"); a.on("pageerror", lambda e: errs.append(str(e)))
    a.get_by_role("button", name="Turn on notifications").click(); a.wait_for_timeout(1000)
    sw=switches(a); print("Aidan:", sw)
    for x in ["Shifts that need coverage","New tasks","Order deadlines","Alerts from staff","Daily cash","Short drawers","Nightly recap","Quiet hours"]: assert x in sw, (x, sw)
    a.locator("#pfLead + .drop button[data-value='4']").dispatch_event("click"); a.wait_for_timeout(500)
    a.locator("#pf-out").uncheck(); a.wait_for_timeout(500)
    a.locator("#pfRecap").fill("03:00"); a.locator("#pfRecap").dispatch_event("change"); a.wait_for_timeout(600)
    prefs=json.loads(sql("select prefs from push_subs where endpoint like '%aidan'")); print("prefs:", prefs)
    assert prefs["lead_hours"]==4 and prefs["out"] is False and prefs["summary_time"]=="03:00" and prefs["cashbook"] and prefs["staff"], prefs
    a.screenshot(path=OUT+"/n1-settings.png", full_page=True)
    # settings come back from the server after a reload
    a.reload(); a.wait_for_timeout(1200); a.locator("#settingsBtn").click(); a.get_by_role("button", name="Notifications").click(); a.wait_for_timeout(800)
    expect(a.locator("#pfLead + .drop .dropbtn")).to_contain_text("4 hours before"); expect(a.locator("#pf-out")).not_to_be_checked()
    a.get_by_role("button", name="Turn off on this phone").click(); a.wait_for_timeout(900)
    expect(a.get_by_role("button", name="Turn on notifications")).to_be_visible()
    assert sql("select count(*) from push_subs where endpoint like '%aidan'")=="0"
    # Brian: a manager, but not on the daily cash list
    br=login(b,"3333","brian"); br.get_by_role("button", name="Turn on notifications").click(); br.wait_for_timeout(1000)
    sw=switches(br); print("Brian:", sw); assert "Daily cash" not in sw and "Alerts from staff" in sw, sw
    # staff: coverage, covered and new tasks, plus quiet hours
    j=login(b,"1111","jill"); j.get_by_role("button", name="Turn on notifications").click(); j.wait_for_timeout(1000)
    sw=switches(j); print("Jill:", sw); assert sw==["Shifts that need coverage","Shifts covered","New tasks","Quiet hours"], sw
    print("ERRORS:", errs); assert not errs; print("PUSH FLOWS PASSED")
