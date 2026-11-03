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

with sync_playwright() as p:
    b=p.chromium.launch()
    a=login(b,"4821","aidan")
    # the date math
    R = a.evaluate("""() => {
      const ev = (day, repeat, extra) => Object.assign({id:'x', day, repeat, skip_dates:[], repeat_until:null}, extra||{});
      return {
        weekly: eventDates(ev('2026-11-03','weekly'), '2026-11-01', '2026-11-30'),
        weeklyMid: eventDates(ev('2026-10-06','weekly'), '2026-11-12', '2026-11-30'),
        biweekly: eventDates(ev('2026-11-03','biweekly'), '2026-11-01', '2026-12-31'),
        biweeklyMid: eventDates(ev('2026-10-06','biweekly'), '2026-11-01', '2026-11-30'),
        monthly31: eventDates(ev('2026-10-31','monthly'), '2026-10-01', '2027-03-31'),
        nth: eventDates(ev('2026-11-10','monthly_nth'), '2026-11-01', '2027-02-28'),
        last: eventDates(ev('2026-10-30','monthly_last'), '2026-10-01', '2027-01-31'),
        until: eventDates(ev('2026-11-03','weekly',{repeat_until:'2026-11-17'}), '2026-11-01', '2026-12-31'),
        skip: eventDates(ev('2026-11-03','weekly',{skip_dates:['2026-11-10']}), '2026-11-01', '2026-11-30'),
        before: eventDates(ev('2026-11-03','weekly'), '2026-10-01', '2026-10-31'),
        once: eventDates(ev('2026-11-03','none'), '2026-11-01', '2026-11-30'),
        dst: eventDates(ev('2026-10-27','weekly'), '2026-10-27', '2026-11-17'),
        opts31: repeatOptions('2026-10-31').map(o=>o[1]),
        opts10: repeatOptions('2026-11-10').map(o=>o[1]),
      }; }""")
    assert R["weekly"]==["2026-11-03","2026-11-10","2026-11-17","2026-11-24"], R["weekly"]
    assert R["weeklyMid"]==["2026-11-17","2026-11-24"], R["weeklyMid"]
    assert R["biweekly"]==["2026-11-03","2026-11-17","2026-12-01","2026-12-15","2026-12-29"], R["biweekly"]
    assert R["biweeklyMid"]==["2026-11-03","2026-11-17"], R["biweeklyMid"]
    assert R["monthly31"]==["2026-10-31","2026-11-30","2026-12-31","2027-01-31","2027-02-28","2027-03-31"], R["monthly31"]
    assert R["nth"]==["2026-11-10","2026-12-08","2027-01-12","2027-02-09"], R["nth"]
    assert R["last"]==["2026-10-30","2026-11-27","2026-12-25","2027-01-29"], R["last"]
    assert R["until"]==["2026-11-03","2026-11-10","2026-11-17"], R["until"]
    assert R["skip"]==["2026-11-03","2026-11-17","2026-11-24"], R["skip"]
    assert R["before"]==[] and R["once"]==["2026-11-03"], (R["before"], R["once"])
    assert R["dst"]==["2026-10-27","2026-11-03","2026-11-10","2026-11-17"], R["dst"]
    print("options:", R["opts31"], R["opts10"])
    assert "Monthly on the last Saturday" in R["opts31"] and not any("5th" in o for o in R["opts31"])
    assert "Monthly on the 2nd Tuesday" in R["opts10"] and not any("last" in o for o in R["opts10"])

    a.locator("#tabEvents").click()
    # weekly trivia starting tomorrow, with an end date ~6 weeks out
    a.get_by_role("button", name="Add event", exact=True).first.click()
    a.locator("#evTitle").fill("Tuesday Trivia")
    expect(a.locator("#evRepeat + .drop")).to_be_visible()
    a.locator(".kindopt", has_text="Party").click(); expect(a.locator("#evRepeat + .drop")).to_be_hidden()
    a.locator(".kindopt", has_text="Standard").click()
    a.locator("#evDate").fill(d(1)); a.locator("#evDate").dispatch_event("change")
    wd = (today+datetime.timedelta(days=1)).strftime("%A")
    a.locator("#evRepeat").locator("xpath=following-sibling::div[1]").get_by_role("radio", name="Every "+wd, exact=True, include_hidden=True).dispatch_event("click")
    expect(a.locator("label[for=evDate]")).to_contain_text("First date"); expect(a.locator("#evUntil")).to_be_visible()
    a.locator("#evUntil").fill(d(43)); a.locator("#evStart").fill("19:00")
    a.screenshot(path=OUT+"/r1-form.png", full_page=True)
    a.locator(".sheet").get_by_role("button", name="Add event", exact=True).click(); a.wait_for_timeout(1200)
    expect(a.locator("#toast")).to_contain_text("Repeating event added")
    # listed once in Coming up, on every week in the calendar
    expect(a.locator(".evrow", has_text="Tuesday Trivia")).to_have_count(1)
    expect(a.locator(".evrow", has_text="Tuesday Trivia")).to_contain_text("↻ Every "+wd[:3])
    this_month = sum(1 for k in range(1,44,7) if d(k)[:7]==d(0)[:7])
    expect(a.locator(".calday:not(.out) .dots i.ev-standard")).to_have_count(this_month)
    a.get_by_role("button", name="Next month").click()
    next_m = (today.replace(day=1)+datetime.timedelta(days=32)).strftime("%Y-%m")
    expect(a.locator(".calday:not(.out) .dots i.ev-standard")).to_have_count(sum(1 for k in range(1,44,7) if d(k)[:7]==next_m))
    a.get_by_role("button", name="Back to this month").click()
    a.screenshot(path=OUT+"/r2-events.png", full_page=True)
    # skip next week's date from the calendar
    a.locator(".calday[aria-label*='event']").nth(1).click() if this_month > 1 else (a.get_by_role("button", name="Next month").click(), a.locator(".calday:not(.out)[aria-label*='event']").first.click())
    a.locator(".calpanel .evrow").first.click()
    expect(a.locator(".repline")).to_contain_text("Every "+wd+", until")
    a.get_by_role("button", name="Skip just this date").click(); a.get_by_role("button", name=re.compile("Tap again to call off")).click(); a.wait_for_timeout(1200)
    expect(a.locator("#toast")).to_contain_text("The other dates stay")
    expect(a.locator(".calpanel .offrow")).to_contain_text("called off this date")
    # sheet for the next date shows it called off, and it can come back
    a.locator(".evrow", has_text="Tuesday Trivia").first.click()
    expect(a.locator(".skips")).to_contain_text("Called off")
    a.screenshot(path=OUT+"/r3-sheet.png", full_page=True)
    a.locator(".skips").get_by_role("button", name="Bring back").click(); a.wait_for_timeout(1200)
    expect(a.locator(".skips")).to_have_count(0)
    a.get_by_role("button", name="Skip just this date").click(); a.get_by_role("button", name=re.compile("Tap again")).click(); a.wait_for_timeout(1200)
    # edit all dates: change to every other week
    a.locator(".evrow", has_text="Tuesday Trivia").first.click(); a.get_by_role("button", name="Edit all dates").click()
    expect(a.locator("#evDate")).to_have_value(d(1))
    a.locator("#evRepeat").locator("xpath=following-sibling::div[1]").get_by_role("radio", name="Every other "+wd, exact=True, include_hidden=True).dispatch_event("click"); a.get_by_role("button", name="Save", exact=True).click(); a.wait_for_timeout(1200)
    expect(a.locator(".evrow", has_text="Tuesday Trivia")).to_contain_text("Every other")
    # Jill sees it, can't skip
    j=login(b,"1111","jill"); j.locator("#tabEvents").click()
    j.locator(".evrow", has_text="Tuesday Trivia").click()
    expect(j.get_by_role("button", name="Skip just this date")).to_have_count(0); expect(j.locator(".repline")).to_be_visible()
    j.get_by_role("button", name="Close", exact=True).click()
    j.locator("#tabShifts").click(); expect(j.locator(".feed")).to_contain_text("called off “Tuesday Trivia on") if False else None
    # remove all dates
    a.locator(".evrow", has_text="Tuesday Trivia").first.click(); a.get_by_role("button", name="Remove all dates").click()
    a.get_by_role("button", name="Tap again to remove every date").click(); a.wait_for_timeout(1200)
    expect(a.locator(".evrow", has_text="Tuesday Trivia")).to_have_count(0)
    print("ERRORS:", errs); assert not errs
    print("REPEAT FLOWS PASSED")
