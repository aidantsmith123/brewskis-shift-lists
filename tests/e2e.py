"""Core flows: logging in, login numbers and inviting people, inventory counts, staff vs manager views,
activity search, and a changed number logging someone out. Run on reset_db.sh (Aidan 4821, Jill 1111)."""
import sys, subprocess, re
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
def sql(q): return subprocess.run(["psql","-h","/var/tmp","-p","54329","-U","postgres","-d","bk","-Atc",q],capture_output=True,text=True,check=True).stdout.strip()
def keypad(pg, digits):
    for d in digits: pg.get_by_role("button", name=d, exact=True).click()
    pg.get_by_role("button", name="Log in").click()
sql("insert into tasks (role_id, text, repeat, added_by_name) values ('opening-bartender','Restock the garnish tray','once','Aidan')")
with sync_playwright() as p:
    b=p.chromium.launch(); errs=[]
    ctx=b.new_context(viewport={"width":390,"height":844}, permissions=["clipboard-read","clipboard-write"])
    pg=ctx.new_page(); pg.on("pageerror", lambda e: errs.append("page: "+str(e)))
    pg.on("console", lambda m: m.type=="error" and "400 (Bad Request)" not in m.text and "fonts.g" not in m.text and "ERR_TUNNEL" not in m.text and errs.append("console: "+m.text))
    pg.goto(URL); pg.locator("#intro").click(); expect(pg.get_by_text("Enter your number")).to_be_visible()
    keypad(pg,"9999"); expect(pg.get_by_text("doesn't match anyone")).to_be_visible()
    keypad(pg,"4821"); expect(pg.locator("#whoName")).to_have_text("Aidan · Mgr")
    pg.wait_for_timeout(600); pg.screenshot(path=OUT+"/1-overview-mgr.png", full_page=True)
    # Team (in Settings): give Brian a number, then send it to him
    pg.locator("#settingsBtn").click(); pg.get_by_role("button", name="Team, roles & login numbers").click()
    card = pg.locator(".person", has_text="Brian")
    card.get_by_role("button", name="Assign number").click()
    pg.locator("#pin-8wtr70oqxiv7p6n22715").fill("1111"); card.get_by_role("button", name="Save number").click()
    expect(pg.get_by_text("already taken")).to_be_visible()
    pg.locator("#pin-8wtr70oqxiv7p6n22715").fill("2468"); card.get_by_role("button", name="Save number").click()
    expect(pg.get_by_text("Brian's login number")).to_be_visible(); expect(pg.locator(".bignum")).to_have_text("2468")
    expect(pg.get_by_role("button", name="Text it to Brian")).to_be_visible()
    pg.get_by_role("button", name="Copy the message").click(); pg.wait_for_timeout(300)
    msg=pg.evaluate("navigator.clipboard.readText()"); print(msg)
    assert "Hi Brian!" in msg and "Your login number is 2468" in msg and "127.0.0.1:8099/" in msg and "Add to Home Screen" in msg
    pg.wait_for_timeout(300); pg.screenshot(path=OUT+"/1b-number.png")
    pg.get_by_role("button", name="Done").click()
    # the invite sheet and the poster
    pg.get_by_role("button", name=re.compile("Invite people")).click()
    expect(pg.locator(".sheet")).to_contain_text("Get the team on the app")
    expect(pg.get_by_role("link", name="Open the sign-up poster")).to_have_attribute("href", URL+"poster.html")
    pg.get_by_role("button", name="Close").click()
    po=ctx.new_page(); po.goto(URL+"poster.html"); po.wait_for_timeout(800)
    expect(po.locator("h1")).to_have_text("Get the Brewski’s app"); expect(po.locator("#url")).to_have_text(URL)
    has_qr = po.locator("#qr svg").count()==1
    print("poster QR drawn:", has_qr, "(needs the CDN)")
    po.screenshot(path=OUT+"/1c-poster.png", full_page=True); po.close()
    # Inventory: starter list, set a par and a supplier, count, deadlines visible
    pg.locator("#tabInv").click()
    expect(pg.get_by_text("Order deadlines")).to_be_visible()
    pg.locator(".fold-head", has_text="Bar supplies").click()
    pg.locator("section", has_text="Bar supplies").get_by_role("button", name="Use a starter list").first.click()
    expect(pg.get_by_role("button", name="Done editing")).to_be_visible()
    pg.locator("input[id^=ep-]").first.fill("6"); pg.locator("input[id^=ep-]").first.press("Enter")
    pg.locator("select[id^=es-]").first.locator("xpath=following-sibling::div[1]").get_by_role("radio", name="Penn Beer", exact=True, include_hidden=True).dispatch_event("click")
    pg.wait_for_timeout(600)
    pg.get_by_role("button", name="Done editing").click()
    if pg.locator(".fold-head", has_text="Bar supplies").get_attribute("aria-expanded")!="true": pg.locator(".fold-head", has_text="Bar supplies").click()
    pg.locator("button[aria-label='One more Limes']").click(); pg.locator("button[aria-label='One more Limes']").click()
    pg.wait_for_timeout(1500)
    expect(pg.locator(".item", has_text="Limes").get_by_text("Order 4")).to_be_visible()
    expect(pg.locator(".card", has_text="Penn Beer").get_by_text("1 to order")).to_be_visible()
    pg.screenshot(path=OUT+"/2-inventory-mgr.png", full_page=True)
    # --- Jill (staff) on another phone
    pj=b.new_page(viewport={"width":390,"height":844}); pj.on("pageerror", lambda e: errs.append("jill: "+str(e)))
    pj.goto(URL); pj.locator("#intro").click(); keypad(pj,"1111"); pj.wait_for_timeout(1500); expect(pj.locator("#whoName")).to_have_text("Jill")
    pj.locator("#settingsBtn").click(); expect(pj.get_by_role("button", name="Team, roles & login numbers")).to_have_count(0)
    pj.locator("#tabShifts").click()
    pj.get_by_role("button", name="Check off Restock the garnish tray").click(); pj.wait_for_timeout(1200)
    assert sql("select done_by_name from tasks where text='Restock the garnish tray'")=="Jill"
    pj.get_by_role("button", name=re.compile("^Done · 1")).click(); expect(pj.locator(".task", has_text="Restock the garnish tray")).to_contain_text("Jill")
    pj.locator("#tabInv").click()
    expect(pj.get_by_text("Order deadlines")).to_be_hidden()
    expect(pj.get_by_text("Penn Beer")).to_be_hidden()
    pj.screenshot(path=OUT+"/3-inventory-staff.png", full_page=True)
    # --- Aidan sees Jill's work and can search for it
    pg.locator("#tabShifts").click(); pg.wait_for_timeout(300)
    pg.evaluate("refresh()"); pg.wait_for_timeout(800)
    pg.locator("#actSearch").fill("jill garnish")
    expect(pg.get_by_text("1 match")).to_be_visible()
    pg.screenshot(path=OUT+"/4-search.png", full_page=False)
    # changing Jill's number logs her out
    pg.locator("#settingsBtn").click(); pg.get_by_role("button", name="Team, roles & login numbers").click()
    pg.locator(".person", has_text="Jill").get_by_role("button", name="Change number").click()
    pg.locator("#pin-bvc7lshrqilod7iy8hzm").fill("1357"); pg.locator(".person", has_text="Jill").get_by_role("button", name="Save number").click()
    pg.get_by_role("button", name="Done").click()
    pj.evaluate("refresh()")
    expect(pj.get_by_role("heading", name="Enter your number")).to_be_visible(timeout=5000)
    # app files reachable
    for i in ["manifest.webmanifest","icons/icon-192.png","icons/icon-512.png","icons/maskable-512.png","sw.js","logo.webp","poster.html",
              "js/core.js","js/account.js","js/ui.js","js/tasks.js","js/inventory.js","js/schedule.js","js/team.js","js/events.js","js/parties.js","js/alerts.js","js/cash.js","js/main.js"]:
        assert pg.request.get(URL+i).ok, i
    sw=pg.request.get(URL+"sw.js").text()
    for f in re.findall(r'"(js/[a-z]+\.js)"', sw): assert pg.request.get(URL+f).ok, f
    print("ERRORS:", errs)
    print("ALL FLOWS PASSED")
    b.close()
