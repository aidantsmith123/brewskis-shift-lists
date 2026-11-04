"""Live updates (v49): a change on one phone shows up on another within a couple of seconds, with a note saying
who did it and a flash on the row; reconnecting after the line drops; holding off while someone's typing.
Also the rolling numbers, the greeting's line about tonight, the pint that fills as you pull to refresh,
and the pint that pours while the app loads. Run on setup_v22.sh."""
import sys, re, json, time, subprocess, datetime, urllib.request
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
def sql(q): return subprocess.run(["psql","-h","/var/tmp","-p","54329","-U","postgres","-d","bk","-Atc",q],capture_output=True,text=True,check=True).stdout.strip()
def live(path=""):
    with urllib.request.build_opener(urllib.request.ProxyHandler({})).open("http://127.0.0.1:8099/__live"+path) as r: return json.loads(r.read())
today=(datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=-5))) - datetime.timedelta(hours=5)).date()
sql("""insert into tasks (id, role_id, text, repeat, added_by_name) values ('t1','opening-bartender','Restock the garnish tray','once','Aidan'),
         ('t2','closing-bartender','Wipe down the taps','once','Aidan'), ('t3','opening-bartender','Cut lemons','once','Aidan');
       insert into items (id, cat_id, name, unit, par) values ('limes','bar-supplies','Limes','cases',4), ('cherries','bar-supplies','Maraschino cherries','jars',3);
       insert into events (id, title, kind, day, start_time, added_by_name) values ('ev1','Trivia Night','entertainment','%s','20:00','Aidan');""" % today)
errs=[]
def said(pg, sel):   # the text as read aloud: rolling digits count once (their screen-reader copy), not as 0–9 strips
    return pg.evaluate("s=>{ const c=document.querySelector(s).cloneNode(true); c.querySelectorAll('.rd').forEach(x=>x.remove()); return c.textContent; }", sel)
def wait_said(pg, sel, text, secs=6):
    for _ in range(int(secs*10)):
        if text in said(pg, sel): return
        time.sleep(0.1)
    raise AssertionError((sel, text, said(pg, sel)))
def login(b, pin, who, **kw):
    ctx=b.new_context(viewport={"width":390,"height":844}, timezone_id="America/New_York", **kw)
    pg=ctx.new_page(); pg.on("pageerror", lambda e: errs.append(who+": "+str(e)))
    pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1500); return pg

with sync_playwright() as p:
    b=p.chromium.launch()
    a=login(b,"4821","aidan"); j=login(b,"1111","jill", has_touch=True)
    expect(a.locator(".tonight")).to_be_visible()
    # both phones are on the live line
    for _ in range(20):
        if live()["joined"] >= 2: break
        time.sleep(0.25)
    print("live:", live()); assert live()["joined"] >= 2

    # the greeting: a line about tonight, and the count rolls
    expect(a.locator(".tn-vibe")).to_have_text("Tonight: Trivia Night at 8 PM")
    print("greeting:", a.locator(".tonight h2").inner_text())

    # Jill checks off a task; Aidan's screen shows it within ~2 seconds, well before the 15-second check
    t0=time.time()
    j.locator(".task", has_text="Restock the garnish tray").get_by_role("button", name="Check off Restock the garnish tray").click()
    j.wait_for_selector(".tn-sum .rs", timeout=2000)   # Jill's count is rolling
    expect(a.locator("#livetoast")).to_be_visible(timeout=4000)
    dt=time.time()-t0; print("Aidan saw it after %.1fs" % dt); assert dt < 3.5, dt
    expect(a.locator("#livetoast")).to_contain_text("Jill checked off “Restock the garnish tray”")
    wait_said(a, ".tn-sum", "1 of 3 done")   # the task moved to the folded Done section
    a.wait_for_timeout(300); a.screenshot(path=OUT+"/live1-toast.png")
    # Jill doesn't get a note about her own change, but her count rolls up
    j.wait_for_timeout(600); assert j.locator("#livetoast:visible").count()==0
    # her count rolls up (a strip of digits sliding), then settles back to plain text
    wait_said(j, ".tn-sum", "1 of 3 done")
    j.wait_for_timeout(1200)
    expect(j.locator(".tn-sum .rd")).to_have_count(0); expect(j.locator(".tn-sum")).to_contain_text("1 of 3 done")
    expect(j.locator(".tn-sum")).to_contain_text("of")
    j.screenshot(path=OUT+"/live2-jill.png")

    # Aidan adds a task for Jill's side; it appears on Jill's phone without her doing anything
    t0=time.time()
    a.get_by_role("button", name="Add task", exact=True).first.click()
    a.locator("#newText").fill("Polish the brass rail")
    a.locator("#newRole").locator("xpath=following-sibling::div[1]").get_by_role("radio", name="Opening bartender", exact=True, include_hidden=True).dispatch_event("click")
    a.locator("form.add").get_by_role("button", name="Add task").click()
    expect(j.locator(".task", has_text="Polish the brass rail")).to_be_visible(timeout=4000)
    print("Jill saw the new task after %.1fs" % (time.time()-t0))
    expect(j.locator("#livetoast")).to_contain_text("Aidan added “Polish the brass rail”")
    expect(j.locator(".task", has_text="Polish the brass rail")).to_have_class(re.compile("live-flash"))

    # counting: Jill counts limes, Aidan's inventory screen updates and flashes the row
    a.locator("#tabInv").click(); a.wait_for_timeout(500)
    a.get_by_role("button", name=re.compile("Bar supplies")).first.click(); a.wait_for_timeout(300)
    j.locator("#tabInv").click(); j.wait_for_timeout(500)
    j.get_by_role("button", name=re.compile("Bar supplies")).first.click(); j.wait_for_timeout(300)
    j.get_by_role("button", name="One more Limes").click(); j.get_by_role("button", name="One more Limes").click()
    expect(a.locator("#cnt-limes")).to_have_value("2", timeout=5000)
    expect(a.locator(".item[data-item='limes']")).to_have_class(re.compile("live-flash"))
    expect(a.locator("#livetoast")).to_contain_text("Jill counted")
    a.screenshot(path=OUT+"/live3-count.png")

    # while Aidan is typing a search, the screen holds still; it catches up when he's done
    a.locator("#invSearch").click(); a.locator("#invSearch").type("li")
    j.get_by_role("button", name="One more Limes").click()
    a.wait_for_timeout(2500)
    expect(a.locator("#invSearch")).to_be_focused(); expect(a.locator("#invSearch")).to_have_value("li")
    assert a.locator("#cnt-limes").input_value()=="2"
    a.locator("#invSearch").blur()
    expect(a.locator("#cnt-limes")).to_have_value("3", timeout=4000)
    a.locator("#invSearch").fill(""); a.locator("#invSearch").blur()

    # the line drops: both phones reconnect by themselves and catch up on what they missed
    live("?drop"); time.sleep(0.3)
    sql("update tasks set done = true, done_by = 'bvc7lshrqilod7iy8hzm', done_by_name = 'Jill', done_at = now(), done_day = (now() at time zone 'America/New_York' - interval '5 hours')::date where id = 't3'")
    for _ in range(40):
        if live()["joined"] >= 2: break
        time.sleep(0.25)
    print("after drop:", live()); assert live()["joined"] >= 2
    a.locator("#tabShifts").click()
    wait_said(a, ".tn-sum", "2 of 4 done")

    # hidden phones hang up; coming back reconnects
    j.evaluate("Object.defineProperty(document,'hidden',{configurable:true,get:()=>true}); document.dispatchEvent(new Event('visibilitychange'))")
    time.sleep(0.6); n=live()["joined"]; print("with Jill hidden:", n); assert n==1, n
    j.evaluate("Object.defineProperty(document,'hidden',{configurable:true,get:()=>false}); document.dispatchEvent(new Event('visibilitychange'))")
    for _ in range(20):
        if live()["joined"] >= 2: break
        time.sleep(0.25)
    assert live()["joined"] >= 2

    # pull to refresh: the pint fills as you pull, and bubbles while it loads
    j.locator("#tabShifts").click(); j.evaluate("window.scrollTo(0,0)"); j.wait_for_timeout(300)
    j.evaluate("""async ()=>{ const t = document.querySelector('#view'); const mk = y => new Touch({identifier:1, target:t, clientX:200, clientY:y});
        t.dispatchEvent(new TouchEvent('touchstart', {touches:[mk(100)], bubbles:true}));
        for (let y = 100; y <= 200; y += 20){ t.dispatchEvent(new TouchEvent('touchmove', {touches:[mk(y)], bubbles:true})); await new Promise(r=>setTimeout(r,16)); } }""")
    half=j.evaluate("document.querySelector('.pint-beer').style.height"); print("pint at 100px pull:", half)
    j.evaluate("""async ()=>{ const t = document.querySelector('#view'); const mk = y => new Touch({identifier:1, target:t, clientX:200, clientY:y});
        for (let y = 200; y <= 260; y += 20){ t.dispatchEvent(new TouchEvent('touchmove', {touches:[mk(y)], bubbles:true})); await new Promise(r=>setTimeout(r,16)); } }""")
    expect(j.locator(".ptr")).to_have_class(re.compile("ready"))
    j.screenshot(path=OUT+"/live4-pull.png", clip={"x":0,"y":0,"width":390,"height":200})
    j.evaluate("document.querySelector('#view').dispatchEvent(new TouchEvent('touchend', {touches:[], bubbles:true}))")
    expect(j.locator(".ptr")).to_have_class(re.compile("spin"))
    j.wait_for_timeout(250); j.screenshot(path=OUT+"/live5-refreshing.png", clip={"x":0,"y":0,"width":390,"height":200})
    expect(j.locator(".ptr")).not_to_have_class(re.compile("spin"), timeout=4000)
    assert half=="66%", half

    # opening the app with nothing saved yet: a pint pours while the first load comes in
    j.evaluate("S.data = null; render()")
    expect(j.locator(".pouring")).to_contain_text("Pouring…")
    j.wait_for_timeout(900); j.screenshot(path=OUT+"/live6-pouring.png")
    j.evaluate("refresh()")
    expect(j.locator(".tonight")).to_be_visible(timeout=8000)

    print("ERRORS:", errs); assert not errs
    print("LIVE PASSED")
