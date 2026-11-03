import sys, re, json, subprocess
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"; errs=[]
def sql(q): return subprocess.run(["psql","-h","/var/tmp","-p","54329","-U","postgres","-d","bk","-Atc",q],capture_output=True,text=True,check=True).stdout.strip()
def login(b, pin, who, scheme="light"):
    ctx=b.new_context(viewport={"width":390,"height":844}, timezone_id="America/New_York", color_scheme=scheme)
    pg=ctx.new_page(); pg.on("pageerror", lambda e: errs.append(who+": "+str(e)))
    pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1300); return pg
sql("select admin_set_pin('Mandy','7777')")
with sync_playwright() as p:
    b=p.chromium.launch()
    k=login(b,"2222","kate")
    btn=k.get_by_role("button", name="Notify a manager"); expect(btn).to_be_visible()
    btn.click()
    expect(k.locator(".sheet h2")).to_have_text("Notify a manager")
    expect(k.locator(".yn input[value=foh]")).to_be_checked()          # Kate is front of house only
    k.locator("#nmWho + .drop .dropbtn").click()
    expect(k.locator("#nmWho + .drop .btnpick button")).to_have_text(["Any manager","Aidan","Mandy"])
    k.locator("#nmWho + .drop .btnpick button", has_text="Mandy").click()
    k.get_by_role("button", name="Send alert").click(); expect(k.locator(".sheet .loginerr")).to_have_text("Say what’s going on.")
    k.locator("#nmText").fill("Guest at table 6 is asking about booking a party")
    k.wait_for_timeout(300); k.screenshot(path=OUT+"/a1-form.png")
    k.get_by_role("button", name="Send alert").click(); k.wait_for_timeout(1200)
    expect(k.locator("#toast")).to_contain_text("Sent to Mandy")
    expect(k.locator(".myalerts .alertrow")).to_contain_text("To Mandy"); expect(k.locator(".myalerts .alertrow")).to_contain_text("Waiting for a manager")
    # second one, back of house, any manager
    btn.click(); k.locator(".yn", has_text="Back of house").click(); k.locator("#nmText").fill("Dish machine is leaking")
    k.get_by_role("button", name="Send alert").click(); k.wait_for_timeout(1200)
    expect(k.locator("#toast")).to_contain_text("Sent to the managers")
    expect(k.locator(".myalerts .alertrow")).to_have_count(2)
    expect(k.locator("main")).not_to_contain_text("alerted")
    k.screenshot(path=OUT+"/a2-staff.png")
    # pushes
    sql("insert into push_subs (endpoint, staff_id, p256dh, auth, prefs, created_at) select 'https://x/'||name, id, 'k','a','{\"quiet\":false}', now()-interval '1 day' from staff where name in ('Aidan','Mandy')")
    al=[(x["endpoint"],x["title"],x["body"]) for x in json.loads(sql("select _push_collect()")) if x["tag"]=="staff"]; print(al)
    assert ("https://x/Mandy","2 alerts from staff") in [(e,t) for e,t,_ in al] and ("https://x/Aidan","Alert for a manager") in [(e,t) for e,t,_ in al]
    # manager
    a=login(b,"7777","mandy")
    expect(a.locator(".bd-row", has_text="staff alerts")).to_contain_text("For you")
    card=a.locator("#staffAlerts"); expect(card).to_contain_text("Alerts from staff"); expect(card.locator(".alertrow")).to_have_count(2)
    expect(card.locator(".alertrow").first).to_contain_text("For you")
    a.wait_for_timeout(300); a.screenshot(path=OUT+"/a3-manager.png")
    card.locator(".alertrow", has_text="Dish machine").get_by_role("button", name="Handled").click(); a.wait_for_timeout(1200)
    expect(a.locator("#staffAlerts .alertrow")).to_have_count(1)
    expect(a.locator(".feed")).to_contain_text("Mandy handled Kate’s alert: Dish machine is leaking")
    k.reload(); k.wait_for_timeout(1500)
    expect(k.locator(".myalerts .alertrow", has_text="Dish machine")).to_contain_text("Handled by Mandy")
    k.screenshot(path=OUT+"/a4-handled.png")
    # dark mode form for a cook (both sides unknown -> none preselected)
    l=login(b,"5555","liam","dark"); l.get_by_role("button", name="Notify a manager").click()
    expect(l.locator(".yn input[value=boh]")).to_be_checked()
    l.wait_for_timeout(300); l.screenshot(path=OUT+"/a5-dark.png")
    b.close()
print("errors:", errs)
