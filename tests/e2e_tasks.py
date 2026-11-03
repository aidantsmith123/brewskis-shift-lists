import sys, re, datetime
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
errs=[]
def login(b, pin, who):
    ctx=b.new_context(viewport={"width":390,"height":844}, timezone_id="America/New_York")
    pg=ctx.new_page(); pg.on("pageerror", lambda e: errs.append(who+": "+str(e)))
    pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1200); return pg
today=(datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=-5))) - datetime.timedelta(hours=5)).date()   # the shift day
def add(pg, text, role=None, star=False, repeat="once", date=None, time=None):
    pg.get_by_role("button", name="Add task", exact=True).first.click()
    pg.locator("#newText").fill(text)
    if star: pg.locator("#newStar").check()
    if role: pg.locator("#newRole").locator("xpath=following-sibling::div[1]").get_by_role("radio", name=role, exact=True, include_hidden=True).dispatch_event("click")
    pg.locator("#newRepeat").locator("xpath=following-sibling::div[1]").locator("button[data-value='%s']" % (repeat)).dispatch_event("click")
    if date: pg.locator("#newDate").fill(date)
    if time: pg.locator("#newTime").fill(time)
    pg.locator("form.add").get_by_role("button", name="Add task").click(); pg.wait_for_timeout(900)

with sync_playwright() as p:
    b=p.chromium.launch()
    a=login(b,"4821","aidan")
    expect(a.locator("#tabShifts")).to_have_text("Tasks")
    expect(a.locator("main")).to_contain_text("No tasks yet")
    add(a, "Fix the walk-in door hinge", star=True, date=str(today+datetime.timedelta(days=1)))
    add(a, "Clean beer lines", role="Closing bartender", repeat="weekly", date=str(today-datetime.timedelta(days=2)))
    add(a, "Boil out the fryer", role="Closing cook", date=str(today))
    add(a, "Health inspection paperwork", star=True)
    rows=a.locator(".task")
    expect(rows).to_have_count(4)
    expect(a.locator(".divider.over")).to_contain_text("Overdue · 1")
    expect(a.locator(".task.overdue")).to_contain_text("Clean beer lines")
    first_todo=a.locator(".task").nth(1); expect(first_todo).to_contain_text("Health inspection paperwork")   # starred first in To do
    expect(a.locator(".task", has_text="Fix the walk-in door")).to_contain_text("Everyone")
    a.screenshot(path=OUT+"/k1-manager.png", full_page=True)

    # Jill (front of house) sees everyone + bar tasks, not kitchen; can check off but not edit
    j=login(b,"1111","jill")
    expect(j.locator(".task")).to_have_count(3); expect(j.locator("main")).not_to_contain_text("Boil out the fryer")
    expect(j.get_by_role("button", name="Add task")).to_have_count(0); expect(j.get_by_role("button", name="Edit")).to_have_count(0)
    j.get_by_role("button", name="★ Important · 2").click(); expect(j.locator(".task")).to_have_count(2)
    j.get_by_role("button", name="For me").click(); expect(j.locator(".task")).to_have_count(3)
    j.get_by_role("button", name="All tasks").click()
    j.get_by_role("button", name="Check off Clean beer lines").click(); j.wait_for_timeout(1000)
    expect(j.locator(".divider.over")).to_have_count(0)
    expect(j.locator(".tonight")).not_to_contain_text("overdue")
    j.get_by_role("button", name=re.compile(r"^Done · 1")).click()
    expect(j.locator(".task.done")).to_contain_text("Done by Jill"); expect(j.locator(".task.done")).to_contain_text("Next due")
    j.screenshot(path=OUT+"/k2-jill.png", full_page=True)
    expect(j.locator(".feed")).to_contain_text("checked off “Clean beer lines”")

    # manager: unstar, edit role, remove
    a.reload(); a.wait_for_timeout(1200)
    t=a.locator(".task", has_text="Health inspection"); t.get_by_role("button", name="Unstar").click(); a.wait_for_timeout(800)
    expect(a.locator(".task.important")).to_have_count(1)
    a.locator(".task", has_text="Boil out").get_by_role("button", name="Edit").click()
    a.locator("#edRole").locator("xpath=following-sibling::div[1]").get_by_role("radio", name="Opening cook", exact=True, include_hidden=True).dispatch_event("click"); a.locator("#edStar").check()
    a.locator("form.edit-task").get_by_role("button", name="Save").click(); a.wait_for_timeout(900)
    expect(a.locator(".task", has_text="Boil out")).to_contain_text("Opening cook"); expect(a.locator(".task.important", has_text="Boil out")).to_have_count(1)
    a.locator(".task", has_text="Fix the walk-in").get_by_role("button", name="Remove").click(); a.get_by_role("button", name="Tap again to remove").click(); a.wait_for_timeout(800)
    expect(a.locator(".list")).not_to_contain_text("Fix the walk-in")
    a.screenshot(path=OUT+"/k3-manager-after.png", full_page=True)
    # staff can get to alerts from the Tasks tab and see the New tasks setting
    j.context.grant_permissions(["notifications"], origin="http://127.0.0.1:8099"); j.add_init_script("Object.defineProperty(Notification, 'permission', {get: ()=>'default'});")
    j.reload(); j.wait_for_timeout(1400); j.locator(".tasks-alert").click(); j.wait_for_timeout(800)
    expect(j.locator("main")).to_contain_text("New tasks for you, your role, or everyone")
    # old role pages are gone; Schedule still fine
    a.locator("#tabSched").click(); expect(a.locator(".coverhero")).to_be_visible()
    print("ERRORS:", errs); assert not errs
    print("TASKS FLOWS PASSED")
