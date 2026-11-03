import sys, re, datetime
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
errs=[]
# the dates come from today, so this runs any day: a pair of days (D1, D2) two or more days out, in the same Mon–Sun week
NY=datetime.timezone(datetime.timedelta(hours=-5))
today=(datetime.datetime.now(NY) - datetime.timedelta(hours=5)).date()
D1=today+datetime.timedelta(days=2)
if D1.weekday()==6: D1+=datetime.timedelta(days=1)
D2=D1+datetime.timedelta(days=1)
MON=D1-datetime.timedelta(days=D1.weekday()); SUN=MON+datetime.timedelta(days=6)
THIS_WEEK = MON <= today <= SUN
def short(d): return d.strftime("%a, %b ")+str(d.day)          # "Sat, Oct 31", like the app
def rng(m): e=m+datetime.timedelta(days=6); return m.strftime("%b ")+str(m.day)+" – "+e.strftime("%b ")+str(e.day)
DAY1=D1.strftime("%A"); DAY2=D2.strftime("%A")
EXAM=today+datetime.timedelta(days=17)   # past the week the test copies shifts into
def login(b, pin, who, dark=False):
    ctx=b.new_context(viewport={"width":390,"height":844}, timezone_id="America/New_York", color_scheme="dark" if dark else "light")
    pg=ctx.new_page(); pg.on("pageerror", lambda e: errs.append(who+": "+str(e)))
    pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1200); return pg
def add_shift(pg, who, role, date, start, end=None, note=""):
    pg.get_by_role("button", name="Add shift", exact=True).first.click()
    pg.locator("#sfWho").locator("xpath=following-sibling::div[1]").get_by_role("radio", name=who, exact=True, include_hidden=True).dispatch_event("click") if who else pg.locator("#sfWho").locator("xpath=following-sibling::div[1]").locator("button[data-value='%s']" % ("")).dispatch_event("click")
    pg.locator("#sfRole").locator("xpath=following-sibling::div[1]").locator("button[data-value='%s']" % (role)).dispatch_event("click")
    pg.locator("#sfDate").fill(date); pg.locator("#sfStart").fill(start)
    if end: pg.locator("#sfClose").uncheck(); pg.locator("#sfEnd").fill(end)
    if note: pg.locator("#sfNote").fill(note)
    pg.locator("#sheet").get_by_role("button", name="Add shift").click(); pg.wait_for_timeout(900)

with sync_playwright() as p:
    b=p.chromium.launch()
    # 1. manager builds the weekend
    a=login(b,"4821","aidan"); a.locator("#tabSched").click()
    if not THIS_WEEK: a.get_by_role("button", name="Next week").click()
    expect(a.locator(".weeklabel")).to_contain_text(rng(MON))
    if THIS_WEEK: expect(a.locator(".weeklabel")).to_contain_text("This week")
    add_shift(a, "Jill", "closing-bartender", D1.isoformat(), "17:00", note="Birthday party")
    add_shift(a, None, "dishwasher", D1.isoformat(), "18:00", "23:00")
    add_shift(a, "Kate", "closing-bartender", D2.isoformat(), "17:00")
    sat = a.locator(".day", has_text=DAY1)
    expect(sat.locator(".srow")).to_have_count(2)
    expect(sat.locator(".srow").first).to_contain_text("Jill"); expect(sat.locator(".srow").first).to_contain_text("Close")
    expect(sat).to_contain_text("Open shift"); expect(sat).to_contain_text("Needs coverage")
    a.screenshot(path=OUT+"/s1-manager-week.png", full_page=True)
    expect(a.locator("#tabSched")).not_to_have_class(re.compile("has-dot"))   # open dish shift isn't nagging the manager

    # 2. Jill gives her Saturday away
    j=login(b,"1111","jill"); expect(j.locator(".tn-shift")).to_contain_text("Next shift"); expect(j.locator(".tn-shift")).to_contain_text(short(D1))
    j.screenshot(path=OUT+"/s2-jill-home.png")
    j.locator("#tabSched").click()
    if not THIS_WEEK: j.get_by_role("button", name="Next week").click()
    j.locator(".day", has_text=DAY1).locator(".srow", has_text="You").click()
    expect(j.locator("#sheet")).to_contain_text("5:00 PM – Close")
    j.locator("#giveNote").fill("Family thing"); j.locator("#sheet").get_by_role("button", name="Ask for coverage").click(); j.wait_for_timeout(900)
    expect(j.locator(".covercard.mine-req")).to_contain_text("You asked for coverage")
    j.screenshot(path=OUT+"/s3-jill-gave.png", full_page=True)

    # 3. Liam (dishwasher) can take the open dish shift but not Jill's bar shift
    l=login(b,"5555","liam"); l.locator("#tabSched").click()
    if not THIS_WEEK: l.get_by_role("button", name="Next week").click()
    grabs=l.locator(".covercard.can"); expect(grabs).to_have_count(1); expect(grabs).to_contain_text("Dishwasher"); expect(l.locator(".covercard", has_text="Jill needs someone")).to_contain_text("Needs a closing bartender")
    l.locator(".day", has_text=DAY1).locator(".srow", has_text="Jill").click()
    expect(l.locator("#sheet")).to_contain_text("Only people with the Closing bartender role can cover this shift")
    l.get_by_role("button", name="Close", exact=True).click()
    grabs.get_by_role("button", name="I'll cover it").click(); l.get_by_role("button", name="Tap again to cover it").click(); l.wait_for_timeout(1000)
    expect(l.locator(".covercard.can")).to_have_count(0)
    expect(l.locator(".day", has_text=DAY1).locator(".srow.is-mine")).to_contain_text("You")

    # 4. Kate takes Jill's shift
    k=login(b,"2222","kate"); expect(k.locator("#tabSched")).to_have_class(re.compile("has-dot"))
    expect(k.locator(".tn-cover")).to_contain_text("Cover Jill's shift?")
    k.locator("#tabSched").click()
    if not THIS_WEEK: k.get_by_role("button", name="Next week").click()
    g=k.locator(".covercard.can"); expect(g).to_contain_text("Jill needs someone"); expect(g).to_contain_text("Family thing")
    k.screenshot(path=OUT+"/s4-kate-grabs.png", full_page=True)
    g.get_by_role("button", name="I'll cover it").click(); k.get_by_role("button", name="Tap again to cover it").click(); k.wait_for_timeout(1000)
    expect(k.locator(".day", has_text=DAY1).locator(".srow.is-mine")).to_contain_text("Closing bartender")
    expect(k.locator("#tabSched")).not_to_have_class(re.compile("has-dot"))

    # 5. Jill sees it went; the log has it; she can't take it back
    j.reload(); j.wait_for_timeout(1300); j.locator("#tabSched").click()
    if not THIS_WEEK: j.get_by_role("button", name="Next week").click()
    expect(j.locator(".covercard.mine-req")).to_have_count(0); expect(j.locator(".covlist")).to_contain_text("Kate is covering you")
    expect(j.locator(".day", has_text=DAY1).locator(".srow", has_text="Kate")).to_be_visible()
    # 6. Kate's calendar links
    k.get_by_role("button", name="Add to my calendar").click(); k.wait_for_timeout(800)
    assert "null" not in k.locator("#sheet").inner_text()
    gl=k.get_by_role("link", name="Add to Google Calendar").get_attribute("href")
    assert gl.startswith("https://calendar.google.com/calendar/render?cid=webcal%3A%2F%2F") and "functions%2Fv1%2Fcalendar%3Ft%3D" in gl, gl
    ap=k.get_by_role("link", name="Add to Apple Calendar").get_attribute("href"); assert ap.startswith("webcal://") and "all=1" not in ap, ap
    expect(k.locator("#sheet").get_by_role("button", name="Whole team")).to_have_count(0)
    old=ap; k.get_by_role("button", name="Reset my link").click(); k.get_by_role("button", name="Tap again to reset your calendar link").click(); k.wait_for_timeout(800)
    assert k.get_by_role("link", name="Add to Apple Calendar").get_attribute("href")!=old
    k.screenshot(path=OUT+"/s5-calendar.png")
    # manager gets a whole-team feed
    a.reload(); a.wait_for_timeout(1300); a.locator("#tabSched").click()
    if not THIS_WEEK: a.get_by_role("button", name="Next week").click()
    a.get_by_role("button", name="Add to my calendar").click(); a.wait_for_timeout(800)
    a.locator("#sheet").get_by_role("button", name="Whole team").click()
    assert "all=1" in a.get_by_role("link", name="Add to Apple Calendar").get_attribute("href")
    a.get_by_role("button", name="Close", exact=True).click()
    feed=a.locator(".feed") if a.locator(".feed").count() else None

    # 7. manager: next week, copy last week, delete one, edit one
    a.get_by_role("button", name="Next week").click(); expect(a.locator(".weeklabel")).to_contain_text(rng(MON+datetime.timedelta(days=7)))
    a.get_by_role("button", name="Copy last week").click(); a.get_by_role("button", name="Tap again: copy last week into this one").click(); a.wait_for_timeout(1200)
    expect(a.locator(".day", has_text=DAY1).locator(".srow")).to_have_count(2)
    expect(a.locator(".day", has_text=DAY2).locator(".srow")).to_have_count(1)
    a.locator(".day", has_text=DAY2).locator(".srow").click(); a.get_by_role("button", name="Edit shift").click()
    a.locator("#sfClose").uncheck(); a.locator("#sfEnd").fill("23:30"); a.locator("#sheet").get_by_role("button", name="Save shift").click(); a.wait_for_timeout(900)
    expect(a.locator(".day", has_text=DAY2).locator(".srow")).to_contain_text("11:30 PM")
    a.locator(".day", has_text=DAY1).locator(".srow").first.click(); a.locator("#delShiftBtn").click(); a.locator("#delShiftBtn").click(); a.wait_for_timeout(900)
    expect(a.locator(".day", has_text=DAY1).locator(".srow")).to_have_count(1)
    a.screenshot(path=OUT+"/s6-next-week.png", full_page=True)
    # far-out week loads from the server
    for _ in range(7): a.get_by_role("button", name="Next week").click()
    a.wait_for_timeout(900); expect(a.locator(".days")).to_be_visible(); expect(a.locator(".back")).to_be_visible()
    a.locator(".back").click(); expect(a.locator(".weeklabel")).to_contain_text("This week")   # back to today
    # activity
    a.locator("#tabShifts").click(); a.wait_for_timeout(600)
    body=a.locator("main").inner_text()
    # 7b. Liam asks for coverage on a shift that isn't on the schedule, removes it, asks again
    l.reload(); l.wait_for_timeout(1300); l.locator("#tabSched").click()
    l.locator(".coverhero").get_by_role("button", name="Ask for coverage").click()
    l.get_by_label("A shift that's not on the schedule").check()
    l.locator("#cfDate").fill(EXAM.isoformat()); l.locator("#cfStart").fill("18:00"); l.locator("#cfClose").uncheck(); l.locator("#cfEnd").fill("23:00")
    l.locator("#cfNote").fill("Exam"); l.locator("#sheet").get_by_role("button", name="Ask for coverage").click(); l.wait_for_timeout(1000)
    mine=l.locator(".covercard.mine-req"); expect(mine).to_contain_text("You asked for coverage"); expect(mine).to_contain_text("Exam"); expect(mine).to_contain_text(short(EXAM))
    l.screenshot(path=OUT+"/c1-liam-asked.png", full_page=True)
    mine.get_by_role("button", name="Remove request").click(); l.get_by_role("button", name="Tap again to remove").click(); l.wait_for_timeout(900)
    expect(l.locator(".covercard.mine-req")).to_have_count(0)
    # his Saturday dish shift (picked up earlier) is on the schedule: he can ask for coverage on it from the list
    l.locator(".coverhero").get_by_role("button", name="Ask for coverage").click()
    expect(l.locator(".choice").first).to_contain_text(short(D1)); l.locator("#sheet").get_by_role("button", name="Ask for coverage").click(); l.wait_for_timeout(900)
    expect(l.locator(".covercard.mine-req")).to_contain_text(short(D1))
    # a staff member's notification settings only show coverage alerts
    l.context.grant_permissions(["notifications"], origin="http://127.0.0.1:8099"); l.add_init_script("Object.defineProperty(Notification, 'permission', {get: ()=>'default'});"); l.reload(); l.wait_for_timeout(1300); l.locator("#tabSched").click(); l.wait_for_timeout(500)
    l.locator(".alertlink").click(); l.wait_for_timeout(800)
    expect(l.locator("main")).to_contain_text("When someone covers your shift"); expect(l.locator("main")).not_to_contain_text("Order deadlines")
    l.screenshot(path=OUT+"/c2-liam-notify.png")
    l.get_by_role("button", name="← Back").click(); expect(l.locator(".coverhero")).to_be_visible()
    # home screen nudges people who can cover
    k.reload(); k.wait_for_timeout(1200); k.screenshot(path=OUT+"/c3-kate-home.png")
    # 8. dark mode look for staff
    d=login(b,"2222","kate-dark",dark=True); d.locator("#tabSched").click(); d.wait_for_timeout(500); d.screenshot(path=OUT+"/s7-dark.png", full_page=True)
    # staff can't see manager tools
    expect(d.get_by_role("button", name="Add shift")).to_have_count(0); expect(d.get_by_role("button", name="Copy last week")).to_have_count(0)
    print("ERRORS:", errs); assert not errs
    print("SCHEDULE FLOWS PASSED")
