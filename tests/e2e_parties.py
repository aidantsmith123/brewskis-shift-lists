import sys, re, datetime, subprocess, json
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
errs=[]
now=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=-4)))
today=(now - datetime.timedelta(hours=5)).date()
def d(n): return (today+datetime.timedelta(days=n)).isoformat()
def sd(n): x=today+datetime.timedelta(days=n); return x.strftime("%a, %b ")+str(x.day)
def sql(q): return subprocess.run(["psql","-h","/var/tmp","-p","54329","-U","postgres","-d","bk","-Atc",q],capture_output=True,text=True,check=True).stdout.strip()
KEY=sql("select value from app_secrets where name='party_form_key'")
def form(rid, **kw):
    data=dict(response_id=rid, **kw)
    return sql("select api_party_form('%s', '%s'::jsonb)" % (KEY, json.dumps(data).replace("'","''")))
def login(b, pin, who, scheme="light"):
    ctx=b.new_context(viewport={"width":390,"height":844}, timezone_id="America/New_York", color_scheme=scheme)
    pg=ctx.new_page(); pg.on("pageerror", lambda e: errs.append(who+": "+str(e)))
    pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1200); return pg

# two inquiries from the form; Joe's booking by phone already takes Sarah's first date
form("r1", submitted_at=now.isoformat(), name="Sarah Miller", phone="610-555-0101", email="sarah@example.com", kind="Birthday",
     date=d(12), backup=d(13), start="19:00", guests="30-40", package="Open Bar + Food Package", notes="Cake at 8. Eagles game on the back TV.")
form("r2", name="Dana Lee", email="dana@example.com", kind="Corporate", date=d(20), guests="about 60", package="Cash Bar")

with sync_playwright() as p:
    b=p.chromium.launch()
    a=login(b,"4821","aidan")
    # settings: the usual deposit
    a.locator("#settingsBtn").click(); a.get_by_role("button", name=re.compile("Party deposit")).click()
    a.locator("#setDeposit").fill("150"); a.get_by_role("button", name="Save", exact=True).click(); a.wait_for_timeout(900)
    expect(a.locator(".setrow", has_text="Party deposit")).to_contain_text("$150")
    a.locator("#tabEvents").click(); a.wait_for_timeout(400)
    # add a phone booking on Sarah's date
    a.get_by_role("button", name="+ Add a booking").click()
    a.locator("#ptName").fill("Joe Smith"); a.locator("#ptPhone").fill("484-555-1212"); a.locator("#ptOcc").fill("Retirement")
    a.locator("#ptDay").fill(d(12)); a.locator("#ptDay").dispatch_event("change"); a.locator("#ptStart").fill("17:00"); a.locator("#ptGuests").fill("25")
    a.locator("#ptPkg + .drop button[data-value=cash_bar]").dispatch_event("click"); a.locator("#ptNotes").fill("Slideshow on the TV")
    expect(a.locator("#ptDeposit")).to_have_value("150")
    a.locator(".kindopt", has_text="Booked").click()
    a.get_by_role("button", name="Add booking").click(); a.wait_for_timeout(1200)
    expect(a.locator("#toast")).to_contain_text("Booked")
    expect(a.locator(".sheet")).to_contain_text("Joe Smith"); a.get_by_role("button", name="Close", exact=True).click()
    expect(a.locator(".partycard")).to_contain_text("2 new inquiries")
    a.screenshot(path=OUT+"/p1-events.png", full_page=True)
    # Sarah: wants a taken date, back-up is free
    a.locator(".partycard .prow", has_text="Sarah M.").click()
    expect(a.locator(".datecheck").first).to_contain_text("Taken: Joe S. · Retirement")
    expect(a.locator(".datecheck").nth(1)).to_contain_text("Free")
    expect(a.locator(".pfacts").first).to_contain_text("~40 guests"); expect(a.locator(".pfacts").first).to_contain_text("Open bar + food")
    expect(a.locator(".contact a", has_text="Email")).to_have_attribute("href", re.compile("^mailto:sarah%40example.com\\?subject=Your%20party"))
    a.wait_for_timeout(600); a.screenshot(path=OUT+"/p2-inquiry.png", full_page=True)
    a.get_by_role("button", name="Hold "+sd(13)).click(); a.wait_for_timeout(1200)
    expect(a.locator(".sheet")).to_contain_text("On hold"); expect(a.locator(".sheet .evsheet-when")).to_contain_text(str((today+datetime.timedelta(days=13)).day))
    a.get_by_role("button", name="Deposit paid").click()
    expect(a.locator("#depAmount")).to_have_value("150"); a.locator(".howpick .kindopt", has_text="Venmo").click()
    a.screenshot(path=OUT+"/p3-deposit.png", full_page=True)
    a.get_by_role("button", name="Save and book it").click(); a.wait_for_timeout(1200)
    expect(a.locator(".sheet")).to_contain_text("Booked"); expect(a.locator(".sheet")).to_contain_text("$150 paid")
    a.screenshot(path=OUT+"/p4-booked.png", full_page=True)
    a.get_by_role("button", name="Close", exact=True).click()
    # calendar shows both, and editing a party event goes to the booking
    expect(a.locator(".evrow:not(.prow)", has_text="Sarah M. · Birthday")).to_have_count(1)
    a.locator(".evrow:not(.prow)", has_text="Joe S. · Retirement").click(); expect(a.locator(".sheet")).to_contain_text("Joe Smith")
    a.get_by_role("button", name="Edit details").click(); a.locator("#ptGuests").fill("28"); a.get_by_role("button", name="Save", exact=True).click(); a.wait_for_timeout(1200)
    expect(a.locator(".sheet")).to_contain_text("28 guests"); a.get_by_role("button", name="Close", exact=True).click()
    # tasks: Dana's reply task with a link to the party; Sarah's confirm task is 9 days out
    a.locator("#tabShifts").click(); a.wait_for_timeout(400)
    t=a.locator(".task", has_text="Reply to party inquiry: Dana L.")
    expect(t).to_be_visible(); t.get_by_role("button", name="🎉 See party").click()
    expect(a.locator(".sheet")).to_contain_text("Dana Lee"); expect(a.locator(".sheet")).to_contain_text("Cash bar")
    a.get_by_role("button", name="Decline").click(); a.get_by_role("button", name="Tap again to decline").click(); a.wait_for_timeout(1200)
    a.locator("#tabShifts").click(); a.wait_for_timeout(400)
    expect(a.locator(".task", has_text="Dana L.")).to_have_count(0)
    a.screenshot(path=OUT+"/p5-tasks.png", full_page=True)
    assert sql("select count(*) from tasks where party_step in ('confirm','setup','thanks')") == "0", sql("select party_step, due_date from tasks where party_id is not null")
    expect(a.locator(".feed")).to_contain_text("took the deposit for Sarah M.")

    # Jill: sees the party, not the money or contact details
    j=login(b,"1111","jill","dark")
    j.locator("#tabEvents").click(); j.wait_for_timeout(400)
    expect(j.locator(".partycard")).to_have_count(0)
    j.locator(".evrow", has_text="Sarah M. · Birthday").click()
    expect(j.locator(".sheet")).to_contain_text("40 guests"); expect(j.locator(".sheet")).to_contain_text("Eagles game")
    expect(j.locator(".sheet")).not_to_contain_text("610-555"); expect(j.locator(".sheet")).not_to_contain_text("$150")
    expect(j.locator(".contact")).to_have_count(0)
    j.wait_for_timeout(600); j.screenshot(path=OUT+"/p6-jill.png", full_page=True)
    j.get_by_role("button", name="Close", exact=True).click()
    j.locator("#tabShifts").click(); j.wait_for_timeout(400); expect(j.locator("main")).not_to_contain_text("asked about a party"); expect(j.locator("main")).not_to_contain_text("deposit")

    # cancel Joe from the calendar sheet -> off the calendar, tasks gone
    a.locator("#tabEvents").click(); a.locator(".evrow", has_text="Joe S.").click()
    a.get_by_role("button", name="Cancel booking").click(); a.get_by_role("button", name="Tap again to cancel it").click(); a.wait_for_timeout(1200)
    expect(a.locator(".evrow", has_text="Joe S.")).to_have_count(0)
    assert sql("select count(*) from tasks where party_step in ('confirm','setup','thanks')") == "0"
    assert not errs, errs
    print("PARTIES PASSED")
