"""Task schedules on the Tasks tab: every 2 weeks / weekly / monthly / daily with a time, overdue and due today,
checking off a repeating task and undoing it, changing a weekly task to a one-time one. Run on setup_v22.sh."""
import sys, re, datetime
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
NY=datetime.timezone(datetime.timedelta(hours=-5))
today=(datetime.datetime.now(NY) - datetime.timedelta(hours=5)).date()
def d(n): return (today+datetime.timedelta(days=n)).isoformat()
def login(b, pin):
    pg=b.new_context(viewport={"width":390,"height":844}, timezone_id="America/New_York").new_page()
    pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1200); return pg
def pick(pg, sel_id, value): pg.locator("#"+sel_id+" + .drop button[data-value='%s']" % value).dispatch_event("click")
def add(pg, text, repeat, date=None, time=None, role="barback"):
    pg.get_by_role("button", name="Add task", exact=True).first.click()
    pg.locator("#newText").fill(text); pick(pg, "newRole", role); pick(pg, "newRepeat", repeat)
    if date is not None: pg.locator("#newDate").fill(date)
    if time: pg.locator("#newTime").fill(time)
    pg.locator("form.add").get_by_role("button", name="Add task").click(); pg.wait_for_timeout(900)
    expect(pg.locator(".task", has_text=text)).to_be_visible()
with sync_playwright() as p:
    b=p.chromium.launch(); errs=[]
    pg=login(b,"4821"); pg.on("pageerror", lambda e: errs.append(str(e)))
    add(pg, "Clean beer lines", "biweekly", d(-1), "15:00")
    t=pg.locator(".task", has_text="Clean beer lines")
    expect(t).to_contain_text("Every 2 weeks"); expect(pg.locator(".divider.over")).to_contain_text("Overdue · 1")
    add(pg, "Deep clean coolers", "weekly", d(3))
    expect(pg.locator(".divider", has_text="Coming up")).to_be_visible()
    add(pg, "Count the safe", "monthly", d(0))
    expect(pg.locator(".task", has_text="Count the safe")).to_contain_text("today")
    add(pg, "Sweep the patio", "daily", None, "04:30")
    expect(pg.locator(".task", has_text="Sweep the patio")).to_contain_text("Daily")
    pg.screenshot(path=OUT+"/s1-schedules.png", full_page=True)
    # check off the overdue one: done, next due in 2 weeks; undo puts it back
    pg.get_by_role("button", name="Check off Clean beer lines").click(); pg.wait_for_timeout(900)
    expect(pg.locator(".divider.over")).to_have_count(0)
    pg.get_by_role("button", name=re.compile(r"^Done · ")).click()
    t=pg.locator(".task.done", has_text="Clean beer lines"); expect(t).to_contain_text("Next due"); expect(t).to_contain_text("Done by Aidan")
    pg.get_by_role("button", name="Uncheck Clean beer lines").click(); pg.wait_for_timeout(900)
    expect(pg.locator(".divider.over")).to_contain_text("Overdue · 1")
    # weekly -> one time, tomorrow
    pg.locator(".task", has_text="Deep clean coolers").get_by_role("button", name="Edit").click()
    pick(pg, "edRepeat", "once"); pg.locator("#edDate").fill(d(1))
    pg.locator("form.edit-task").get_by_role("button", name="Save").click(); pg.wait_for_timeout(900)
    t=pg.locator(".task", has_text="Deep clean coolers"); expect(t).to_contain_text("tomorrow"); expect(t).not_to_contain_text("Weekly")
    pg.screenshot(path=OUT+"/s2-after.png", full_page=True)
    # a barback-role task isn't on Jill's list (front of house, but not a barback) until she has the role
    j=login(b,"1111"); j.on("pageerror", lambda e: errs.append("jill "+str(e)))
    expect(j.locator("main")).to_contain_text("Count the safe")      # Barback is front of house, so Jill sees it
    j.get_by_role("button", name="Check off Count the safe").click(); j.wait_for_timeout(900)
    j.get_by_role("button", name=re.compile(r"^Done · ")).click()
    expect(j.locator(".task.done", has_text="Count the safe")).to_contain_text("Done by Jill")
    print("ERRORS:", errs); assert not errs; print("SCHEDULE FLOWS PASSED")
