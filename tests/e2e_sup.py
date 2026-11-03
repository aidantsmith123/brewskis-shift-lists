import sys, datetime
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
now=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=-4)))
today=(now - datetime.timedelta(hours=5)).date()
def d(n): return (today+datetime.timedelta(days=n)).isoformat()
def supcard(pg, name):
    cards = pg.locator(".card:has(input[id^='sn-'])")
    for i in range(cards.count()):
        if cards.nth(i).locator("input[id^='sn-']").input_value() == name: return cards.nth(i)
    raise AssertionError("no card for "+name)
with sync_playwright() as p:
    b=p.chromium.launch(); errs=[]
    ctx=b.new_context(viewport={"width":390,"height":844}, timezone_id="America/New_York")
    pg=ctx.new_page(); pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL)
    for x in "4821": pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); expect(pg.locator("#whoName")).to_have_text("Aidan · Mgr")
    pg.get_by_role("button", name="Inventory", exact=True).click()
    # Muller was ordered the day after Tuesday's cutoff: a late order for last week, so next Tuesday still needs ordering
    mul = pg.locator(".card", has_text="Muller Beverage")
    expect(mul.get_by_text("Order by", exact=False)).to_be_visible(); expect(mul.get_by_text("Last order placed by Aidan")).to_be_visible()
    pg.get_by_role("button", name="Edit lists & pars").click()
    # Penn Beer: weekly -> every 2 weeks starting in 5 days, 11 AM
    card = supcard(pg, "Penn Beer")
    card.locator("select[id$='-Sched']").locator("xpath=following-sibling::div[1]").locator("button[data-value='%s']" % ("biweekly")).dispatch_event("click"); pg.wait_for_timeout(600)
    card = supcard(pg, "Penn Beer")
    card.locator("input[id$='-Start']").fill(d(5)); card.locator("input[id$='-Start']").dispatch_event("change"); pg.wait_for_timeout(600)
    card = supcard(pg, "Penn Beer")
    card.locator("input[id$='-Cut']").fill("11:00"); card.locator("input[id$='-Cut']").dispatch_event("change"); pg.wait_for_timeout(600)
    expect(supcard(pg, "Penn Beer").get_by_text("Order every other")).to_be_visible()
    # New monthly supplier
    pg.locator("#nsName").fill("Restaurant Depot")
    pg.locator("#nsSched").locator("xpath=following-sibling::div[1]").locator("button[data-value='%s']" % ("monthly")).dispatch_event("click"); pg.locator("#nsStart").fill(d(2)); pg.locator("#nsStart").dispatch_event("change")
    expect(pg.get_by_text("of every month")).to_be_visible()
    pg.get_by_role("button", name="Add supplier").click(); pg.wait_for_timeout(800); supcard(pg, "Restaurant Depot")
    # One-time supplier in the past -> Missed
    pg.locator("#nsName").fill("Party Rentals")
    pg.locator("#nsSched").locator("xpath=following-sibling::div[1]").locator("button[data-value='%s']" % ("once")).dispatch_event("click"); pg.locator("#nsStart").fill(d(-2)); pg.locator("#nsStart").dispatch_event("change")
    pg.get_by_role("button", name="Add supplier").click(); pg.wait_for_timeout(800); supcard(pg, "Party Rentals")
    pg.screenshot(path=OUT+"/u1-supplier-edit.png", full_page=True)
    pg.get_by_role("button", name="Done editing").click()
    penn = pg.locator(".card", has_text="Penn Beer")
    expect(penn.get_by_text("Every 2 weeks")).to_be_visible()
    rd = pg.locator(".card", has_text="Restaurant Depot"); expect(rd.get_by_text("Monthly ·")).to_be_visible()
    expect(pg.locator(".card", has_text="Party Rentals").get_by_text("Missed", exact=True)).to_be_visible()
    # mark Restaurant Depot ordered -> Ordered, button gone
    rd.get_by_role("button", name="Mark order placed").click()
    rd = pg.locator(".card", has_text="Restaurant Depot")
    expect(rd.get_by_text("Ordered", exact=True)).to_be_visible(); expect(rd.get_by_role("button", name="Mark order placed")).to_have_count(0)
    pg.screenshot(path=OUT+"/u2-deadlines.png", full_page=True)
    # changing the schedule starts a fresh round
    pg.get_by_role("button", name="Edit lists & pars").click()
    card = supcard(pg, "Restaurant Depot")
    card.locator("input[id$='-Cut']").fill("08:00"); card.locator("input[id$='-Cut']").dispatch_event("change"); pg.wait_for_timeout(800)
    pg.get_by_role("button", name="Done editing").click()
    expect(pg.locator(".card", has_text="Restaurant Depot").get_by_role("button", name="Mark order placed")).to_be_visible()
    # home screen strip points at a supplier that still needs ordering
    pg.get_by_role("button", name="Tasks", exact=True).click()
    strip = pg.locator(".tn-order"); expect(strip).to_be_visible(); assert "Restaurant Depot" not in strip.inner_text() or "Mark" not in strip.inner_text(), strip.inner_text()
    print("strip:", strip.inner_text().replace("\n"," | "))
    print("ERRORS:", errs); print("SUPPLIER FLOWS PASSED")
