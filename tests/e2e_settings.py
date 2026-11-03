import sys
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
errs=[]
def login(b, pin, who, scheme="light"):
    ctx=b.new_context(viewport={"width":390,"height":844}, timezone_id="America/New_York", color_scheme=scheme)
    pg=ctx.new_page(); pg.on("pageerror", lambda e: errs.append(who+": "+str(e)))
    pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1200); return pg
with sync_playwright() as p:
    b=p.chromium.launch()
    a=login(b,"4821","aidan")
    expect(a.locator("#settingsBtn")).to_be_visible()
    a.locator("#tabEvents").click(); a.locator("#settingsBtn").click()
    expect(a.locator("main h2").first).to_have_text("Settings"); expect(a.locator("#settingsBtn")).to_have_attribute("aria-pressed","true")
    expect(a.locator("#tabs button[aria-pressed=true]")).to_have_count(0)
    expect(a.locator(".acct")).to_contain_text("Aidan")
    a.wait_for_timeout(600); a.screenshot(path=OUT+"/s1-settings.png", full_page=True)
    # dark mode sticks after a reload
    a.get_by_role("radio", name="Dark").click()
    assert a.evaluate("document.documentElement.dataset.theme")=="dark"
    a.reload(); a.wait_for_timeout(1500)
    assert a.evaluate("document.documentElement.dataset.theme")=="dark"
    bg = a.evaluate("getComputedStyle(document.body).backgroundColor"); assert bg=="rgb(21, 16, 11)", bg
    a.locator("#settingsBtn").click(); expect(a.get_by_role("radio", name="Dark")).to_have_attribute("aria-checked","true")
    a.wait_for_timeout(500); a.screenshot(path=OUT+"/s2-dark.png", full_page=True)
    a.get_by_role("radio", name="Automatic").click(); assert a.evaluate("document.documentElement.dataset.theme") is None
    # sound switch
    a.locator("#soundToggle").uncheck(); assert a.evaluate("localStorage.getItem('brewskis.sound')")=="off"
    # notifications row goes to notification settings and back
    a.get_by_role("button", name="Notifications").click(); expect(a.locator("main h2").first).to_have_text("Notifications")
    a.get_by_role("button", name="← Back").click(); expect(a.locator("main h2").first).to_have_text("Settings")
    # gear again goes back to where you were
    a.locator("#settingsBtn").click(); expect(a.locator("#tabs button[aria-pressed=true]")).to_have_count(1)
    # manager link to team
    a.locator("#settingsBtn").click(); a.get_by_role("button", name="Team, roles & login numbers").click()
    expect(a.locator("main h2").first).to_have_text("Team"); expect(a.locator("#settingsBtn")).to_have_attribute("aria-pressed","true")
    expect(a.locator("#tabs button")).to_have_count(5); expect(a.locator("#tabs button[aria-pressed=true]")).to_have_count(0)
    a.wait_for_timeout(500); a.screenshot(path=OUT+"/t1-team.png")
    a.get_by_role("button", name="← Settings").click(); expect(a.locator("main h2").first).to_have_text("Settings")
    a.get_by_role("button", name="Team, roles & login numbers").click(); a.locator("#settingsBtn").click()
    expect(a.locator("#tabs button[aria-pressed=true]")).to_have_count(1)
    # staff: no managers section; name button opens settings; log out works
    j=login(b,"1111","jill")
    j.locator("#whoBtn").click(); expect(j.locator("main h2").first).to_have_text("Settings")
    expect(j.get_by_text("Team, roles & login numbers")).to_have_count(0)
    j.get_by_role("button", name="Log out").click(); expect(j.get_by_text("Enter your number")).to_be_visible(); expect(j.locator("#settingsBtn")).to_be_hidden()
    print("ERRORS:", errs); assert not errs
    print("SETTINGS FLOWS PASSED")
