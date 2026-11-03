import sys, re, datetime
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
errs=[]
now=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=-4)))
today=(now - datetime.timedelta(hours=5)).date()
def d(n): return (today+datetime.timedelta(days=n)).isoformat()
def login(b, pin, who):
    ctx=b.new_context(viewport={"width":390,"height":844}, timezone_id="America/New_York")
    pg=ctx.new_page(); pg.on("pageerror", lambda e: errs.append(who+": "+str(e)))
    pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1200); return pg
def start(pg, title, kind, day):
    pg.get_by_role("button", name="Add event", exact=True).first.click()
    pg.locator("#evTitle").fill(title); pg.locator(".kindopt", has_text=kind).click()
    pg.locator("#evDate").fill(day); pg.locator("#evDate").dispatch_event("change")
save = lambda pg: (pg.locator(".sheet").get_by_role("button", name="Add event", exact=True).click(), pg.wait_for_timeout(1200))

with sync_playwright() as p:
    b=p.chromium.launch()
    a=login(b,"4821","aidan"); a.locator("#tabEvents").click()
    # Party: off by default, tick it -> 3 promotion tasks
    start(a, "Eagles watch party", "Party", d(20))
    expect(a.locator("#evPromote")).not_to_be_checked(); expect(a.locator(".promohint")).to_be_hidden()
    a.locator("#evPromote").check(); expect(a.locator(".promohint li")).to_have_count(3)
    a.screenshot(path=OUT+"/p1-form.png", full_page=True)
    save(a); expect(a.locator("#toast")).to_contain_text("plus 3 promotion tasks")
    expect(a.locator(".evrow", has_text="Eagles")).to_contain_text("Promoted 0 of 3")
    # Entertainment: on by default; untick it -> no tasks
    start(a, "Acoustic night", "Entertainment", d(25))
    expect(a.locator("#evPromote")).to_be_checked()
    a.locator("#evPromote").uncheck(); save(a)
    expect(a.locator(".evrow", has_text="Acoustic")).not_to_contain_text("Promoted")
    # once you've set it, changing the type doesn't flip it
    start(a, "Chili cook-off", "Other", d(30))
    a.locator("#evPromote").check(); a.locator(".kindopt", has_text="Standard").click(); expect(a.locator("#evPromote")).to_be_checked()
    # repeating turns it off
    a.locator("#evRepeat + .drop .btnpick button").nth(1).dispatch_event("click"); expect(a.locator("#evPromote")).to_be_disabled()
    expect(a.locator(".promobox")).to_contain_text("Repeating events can't get promotion reminders")
    a.locator("#evRepeat + .drop .btnpick button").nth(0).dispatch_event("click"); expect(a.locator("#evPromote")).to_be_enabled(); save(a)
    # turn promotion on for an existing event, then off again
    a.locator(".evrow", has_text="Acoustic").click(); a.get_by_role("button", name="Edit event").click()
    expect(a.locator("#evPromote")).not_to_be_checked(); a.locator("#evPromote").check()
    a.get_by_role("button", name="Save", exact=True).click(); a.wait_for_timeout(1200)
    expect(a.locator(".evrow", has_text="Acoustic")).to_contain_text("Promoted 0 of 3")
    a.locator("#tabShifts").click()
    expect(a.locator(".task.important", has_text="Promote")).to_have_count(9)
    expect(a.locator(".task", has_text="Promote Eagles watch party · 1 week out").get_by_role("button", name="📣 See event")).to_be_visible()
    a.screenshot(path=OUT+"/p2-tasks.png", full_page=True)
    a.locator("#tabEvents").click(); a.locator(".evrow", has_text="Chili").click(); a.get_by_role("button", name="Edit event").click()
    a.locator("#evPromote").uncheck(); a.get_by_role("button", name="Save", exact=True).click(); a.wait_for_timeout(1200)
    a.locator("#tabShifts").click(); expect(a.locator(".task", has_text="Promote Chili")).to_have_count(0)
    print("ERRORS:", errs); assert not errs
    print("PROMOTE FLOWS PASSED")
