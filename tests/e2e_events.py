import sys, re, datetime
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
errs=[]
now=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=-4)))
today=(now - datetime.timedelta(hours=5)).date()
def d(n): return (today+datetime.timedelta(days=n)).isoformat()
def login(b, pin, who, scheme="light"):
    ctx=b.new_context(viewport={"width":390,"height":844}, timezone_id="America/New_York", color_scheme=scheme)
    pg=ctx.new_page(); pg.on("pageerror", lambda e: errs.append(who+": "+str(e)))
    pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1200); return pg
def add_event(pg, title, kind, day, start=None, end=None, notes=None):
    pg.get_by_role("button", name="Add event", exact=True).first.click()
    pg.locator("#evTitle").fill(title)
    pg.locator(".kindopt", has_text=kind).click()
    pg.locator("#evDate").fill(day); pg.locator("#evDate").dispatch_event("change")
    if start: pg.locator("#evStart").fill(start)
    if end: pg.locator("#evEnd").fill(end)
    if notes: pg.locator("#evNotes").fill(notes)

with sync_playwright() as p:
    b=p.chromium.launch()
    a=login(b,"4821","aidan")
    # all five tabs fit on a phone
    for t in ["Tasks","Inventory","Shifts","Events"]: expect(a.locator("#tabs").get_by_role("button", name=t, exact=True)).to_be_visible()
    assert a.evaluate("document.documentElement.scrollWidth") <= 390, "page scrolls sideways"
    a.locator("#tabEvents").click()
    expect(a.locator("main")).to_contain_text("Nothing on the calendar")
    # entertainment event 20 days out: the form previews the three reminders
    add_event(a, "Comedy Night", "Entertainment", d(20), "20:00", "23:00", "Two comics from Philly. $5 cover.")
    expect(a.locator(".promohint li")).to_have_count(3); expect(a.locator(".promohint li.past")).to_have_count(0)
    a.screenshot(path=OUT+"/e1-form.png", full_page=True)
    a.locator(".sheet").get_by_role("button", name="Add event", exact=True).click(); a.wait_for_timeout(1200)
    expect(a.locator("#toast")).to_contain_text("plus 3 promotion tasks")
    expect(a.locator(".evhero")).to_contain_text("Comedy Night")
    # a party next weekend, and something tonight
    add_event(a, "Halloween costume party", "Party", d(1), "21:00", notes="Best costume wins a $50 tab")
    a.locator(".sheet").get_by_role("button", name="Add event", exact=True).click(); a.wait_for_timeout(1000)
    add_event(a, "Beer delivery inspection", "Standard", d(0))
    a.locator(".sheet").get_by_role("button", name="Add event", exact=True).click(); a.wait_for_timeout(1000)
    # entertainment 10 days out: the 2-week reminder is already past
    add_event(a, "Trivia", "Entertainment", d(10), "19:00")
    expect(a.locator(".promohint li.past")).to_have_count(1)
    a.locator(".sheet").get_by_role("button", name="Add event", exact=True).click(); a.wait_for_timeout(1000)
    expect(a.locator("#toast")).to_contain_text("plus 2 promotion tasks")
    a.get_by_role("button", name="Back to this month").click() if a.get_by_role("button", name="Back to this month").count() else None
    a.wait_for_timeout(300)
    expect(a.locator(".evhero")).to_contain_text("Beer delivery inspection")
    expect(a.locator(".evrow")).to_have_count(4)
    a.screenshot(path=OUT+"/e2-events.png", full_page=True)
    # tap a day on the calendar
    a.locator(".calday.today").click(); expect(a.locator(".calpanel")).to_contain_text("Beer delivery inspection")
    a.locator(".calday.today").click(); expect(a.locator(".calpanel")).to_have_count(0)
    # next month shows Comedy Night when it falls there
    if d(20)[:7] != d(0)[:7]:
        a.get_by_role("button", name="Next month").click(); expect(a.locator(".calday:not(.out)[aria-label*=\"event\"]").first).to_be_visible()
        a.get_by_role("button", name="Back to this month").click()
    # details sheet with promotion checklist
    a.locator(".evrow", has_text="Comedy Night").click()
    expect(a.locator(".promorow")).to_have_count(3)
    a.screenshot(path=OUT+"/e3-sheet.png", full_page=True)
    a.locator(".promorow").first.locator(".check").click(); a.wait_for_timeout(1200)
    expect(a.locator(".promorow.done")).to_have_count(1)
    a.get_by_role("button", name="Close", exact=True).click()
    expect(a.locator(".evrow", has_text="Comedy Night")).to_contain_text("Promoted 1 of 3")
    # tasks tab: 5 starred promo tasks with links back, and the strip for today's event
    a.locator("#tabShifts").click(); a.wait_for_timeout(500)
    expect(a.locator(".task.important", has_text="Promote")).to_have_count(4)
    expect(a.locator(".tn-event", has_text="Beer delivery inspection")).to_be_visible(); expect(a.locator(".tn-event")).to_have_count(2)
    a.screenshot(path=OUT+"/e4-tasks.png", full_page=True)
    a.locator(".task", has_text="Promote Trivia · 1 week out").get_by_role("button", name="📣 See event").click()
    expect(a.locator(".sheet")).to_contain_text("Trivia"); a.get_by_role("button", name="Close", exact=True).click()
    # change Trivia to Party -> its promo tasks go away
    a.locator(".evrow", has_text="Trivia").click(); a.get_by_role("button", name="Edit event").click()
    a.locator(".kindopt", has_text="Party").click(); expect(a.locator("#evPromote")).to_be_checked(); a.locator("#evPromote").uncheck()
    a.get_by_role("button", name="Save", exact=True).click(); a.wait_for_timeout(1200)
    a.locator("#tabShifts").click(); expect(a.locator(".task", has_text="Promote")).to_have_count(2)

    # Jill: sees events, no add button, no promotion details
    j=login(b,"1111","jill","dark")
    expect(j.locator(".tn-event").first).to_be_visible()
    j.locator("#tabEvents").click()
    expect(j.locator(".evrow")).to_have_count(4); expect(j.get_by_role("button", name="Add event")).to_have_count(0)
    expect(j.locator(".evrow", has_text="Comedy Night")).not_to_contain_text("Promoted")
    j.screenshot(path=OUT+"/e5-jill-dark.png", full_page=True)
    j.locator(".evrow", has_text="Comedy Night").click()
    expect(j.locator(".promo")).to_have_count(0); expect(j.get_by_role("button", name="Edit event")).to_have_count(0)
    j.get_by_role("button", name="Close", exact=True).click()
    j.locator("#tabShifts").click(); expect(j.locator(".feed")).to_contain_text("added “Comedy Night”")

    # manager removes Comedy Night -> promo tasks gone
    a.locator("#tabEvents").click(); a.locator(".evrow", has_text="Comedy Night").click()
    a.get_by_role("button", name="Remove event").click(); a.get_by_role("button", name=re.compile("Tap again")).click(); a.wait_for_timeout(1200)
    expect(a.locator(".evrow", has_text="Comedy Night")).to_have_count(0)
    a.locator("#tabShifts").click(); expect(a.locator(".task", has_text="Promote")).to_have_count(0)
    print("ERRORS:", errs); assert not errs
    print("EVENTS FLOWS PASSED")
