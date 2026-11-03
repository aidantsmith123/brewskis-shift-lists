import sys, json, os
REPO=os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"; VJ=os.path.join(REPO,"site","version.json")
orig=open(VJ).read()
import re; V=int(re.search(r"APP_VERSION = (\d+)", open(os.path.join(REPO,"site","js","core.js")).read()).group(1))
def login(pg, pin):
    pg.goto(URL)
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click()
try:
  with sync_playwright() as p:
    b=p.chromium.launch(); errs=[]
    # Jill opens the app on her phone
    cj=b.new_context(viewport={"width":390,"height":844}, user_agent="Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 Mobile/15E148")
    pj=cj.new_page(); pj.on("pageerror", lambda e: errs.append("jill "+str(e))); login(pj,"1111"); expect(pj.locator("#whoName")).to_have_text("Jill"); pj.wait_for_timeout(800)
    # Aidan opens Team from Settings
    ca=b.new_context(viewport={"width":390,"height":844}); pa=ca.new_page(); pa.on("pageerror", lambda e: errs.append(str(e)))
    login(pa,"4821"); expect(pa.locator("#whoName")).to_have_text("Aidan · Mgr")
    pa.locator("#settingsBtn").click(); pa.get_by_role("button", name="Team, roles & login numbers").click()
    jill=pa.locator(".person", has_text="Jill")
    expect(jill.get_by_text("Up to date")).to_be_visible(); expect(jill.get_by_text("iPhone browser")).to_be_visible()
    expect(pa.locator(".vsummary")).to_contain_text("Everyone is on the latest version")
    pa.screenshot(path=OUT+"/v1-team.png", full_page=True)
    # account sheet shows the version
    pa.locator("#whoBtn").click(); expect(pa.get_by_text(f"App version {V}")).to_be_visible(); expect(pa.locator("main").get_by_text("Up to date")).to_be_visible()
    pa.locator("#tabShifts").click()
    # a new version is published while Aidan has a form open: no automatic update, the bar shows instead
    pa.evaluate("openSheet(h('h2',{text:'Busy'}))")
    open(VJ,"w").write(json.dumps({"version":V+1,"date":"2026-10-30"}))
    pa.evaluate("checkLatest(true)"); pa.evaluate("document.dispatchEvent(new Event('visibilitychange'))"); pa.wait_for_timeout(1200)
    expect(pa.locator("#updatebar")).to_be_visible(); expect(pa.locator("#updatebar")).to_contain_text(f"Version {V+1}")
    expect(pa.locator(".sheet h2")).to_have_text("Busy")          # not reloaded under him
    pa.evaluate("closeSheet()")
    pa.locator("#settingsBtn").click(); pa.get_by_role("button", name="Team, roles & login numbers").click(); pa.wait_for_timeout(800)
    expect(pa.locator(".person", has_text="Jill").get_by_text("Needs update")).to_be_visible()
    expect(pa.locator(".vsummary")).to_contain_text("0 of")
    pa.screenshot(path=OUT+"/v2-behind.png", full_page=True)
    # nothing open: bringing the app back installs it by itself, and he stays on the same page
    with pa.expect_navigation():
        pa.evaluate("document.activeElement && document.activeElement.blur(); document.dispatchEvent(new Event('visibilitychange'))")
    pa.wait_for_timeout(2600)
    expect(pa.locator("#whoName")).to_have_text("Aidan · Mgr")   # still logged in after the reload
    expect(pa.locator("#toast")).to_contain_text(f"Updated to version {V+1}")
    expect(pa.locator("main h2").first).to_have_text("Team")
    # the files didn't really change (still version V), so it must not keep reloading
    reloads=[]; pa.on("framenavigated", lambda f: reloads.append(f.url))
    pa.evaluate("checkLatest(true)"); pa.evaluate("document.dispatchEvent(new Event('visibilitychange'))"); pa.wait_for_timeout(2500)
    assert not reloads, reloads
    expect(pa.locator("#updatebar")).to_be_visible()
    # the update bar still works by hand
    pa.locator("#updateBtn").click(); pa.wait_for_load_state(); pa.wait_for_timeout(1500)
    expect(pa.locator("#whoName")).to_have_text("Aidan · Mgr")
    print("ERRORS:", errs); print("VERSION FLOWS PASSED")
finally:
  open(VJ,"w").write(orig)
