import sys, re, datetime, subprocess, json
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
errs=[]
now=datetime.datetime.now(datetime.timezone(datetime.timedelta(hours=-5)))
today=(now - datetime.timedelta(hours=5)).date()
def d(n): return (today+datetime.timedelta(days=n)).isoformat()
def sql(q): return subprocess.run(["psql","-h","/var/tmp","-p","54329","-U","postgres","-d","bk","-Atc",q],capture_output=True,text=True,check=True).stdout.strip()
def login(b, pin, who, scheme="light"):
    ctx=b.new_context(viewport={"width":390,"height":844}, timezone_id="America/New_York", color_scheme=scheme, accept_downloads=True)
    pg=ctx.new_page(); pg.on("pageerror", lambda e: errs.append(who+": "+str(e)))
    pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1200); return pg
late = now.hour >= 17 or now.hour < 5
def row(pg, name): return pg.locator(".cashtonight .cashrow").filter(has=pg.locator("b", has_text=re.compile("^"+name+"$")))

with sync_playwright() as p:
    b=p.chromium.launch()
    a=login(b,"4821","aidan")
    k0=login(b,"2222","kate0"); expect(k0.locator("#tabCash")).to_be_hidden(); k0.context.close()
    a.locator("#tabCash").click()
    expect(a.locator(".empty")).to_contain_text("Set up your drawers")
    a.get_by_role("button", name="Add a drawer").click()
    a.locator("#drName").fill("Back Bar"); a.get_by_role("button", name="Add drawer").click(); a.wait_for_timeout(900)
    a.get_by_role("button", name="+ Add a drawer").click(); a.locator("#drName").fill("Front Bar"); a.get_by_role("button", name="Add drawer").click(); a.wait_for_timeout(900)
    expect(a.locator(".cashtonight .cashrow")).to_have_count(2)
    a.screenshot(path=OUT+"/s1-setup.png", full_page=True)

    l=login(b,"5555","liam"); expect(l.locator("#tabCash")).to_be_hidden()

    k=login(b,"2222","kate")
    if late: expect(k.locator(".bd-row", has_text="Cash-out")).to_contain_text("2 drawers"); expect(k.locator("#tabCash")).to_have_class(re.compile("has-dot"))
    k.locator("#tabCash").click()
    expect(k.locator(".refill")).to_have_count(0); expect(k.locator(".cashstats")).to_have_count(0)
    row(k,"Back Bar").get_by_role("button", name="Cash out").click()
    expect(k.locator(".sheet")).to_contain_text("Expected deposit")
    expect(k.locator("#coAmount")).to_be_hidden()
    k.get_by_role("button", name="Save", exact=True).click(); expect(k.locator(".sheet .loginerr")).to_have_text("Pick whether the drawer is short.")
    k.locator(".yn", has_text="Yes, it's short").click(); expect(k.locator("#coAmount")).to_be_visible()
    k.get_by_role("button", name="Save", exact=True).click(); expect(k.locator(".sheet .loginerr")).to_have_text("Enter how much it's short.")
    k.locator("#coAmount").fill("6.22"); k.locator("#coNote").fill("Tips were more than cash")
    k.wait_for_timeout(300); k.screenshot(path=OUT+"/s2-short.png")
    k.get_by_role("button", name="Save", exact=True).click(); k.wait_for_timeout(1200)
    expect(k.locator("#toast")).to_contain_text("Back Bar short $6.22")
    expect(row(k,"Back Bar")).to_contain_text("Short $6.22")
    # Front Bar: not short
    row(k,"Front Bar").get_by_role("button", name="Cash out").click()
    k.locator(".yn", has_text="No").click(); k.get_by_role("button", name="Save", exact=True).click(); k.wait_for_timeout(1200)
    expect(row(k,"Front Bar")).to_contain_text("Not short")
    expect(k.locator("#tabCash")).not_to_have_class(re.compile("has-dot"))
    k.wait_for_timeout(400); k.screenshot(path=OUT+"/s3-kate-tab.png")
    # change it: tap the row
    row(k,"Back Bar").click(); expect(k.locator("#coAmount")).to_have_value("6.22"); expect(k.locator(".yn input[value=true]")).to_be_checked()
    k.get_by_role("button", name="Cancel").click()
    k.locator("#tabShifts").click()
    if late: expect(k.locator(".bd-row", has_text="Cash-out")).to_contain_text("Back Bar short $6.22")
    expect(k.locator("main")).not_to_contain_text("cashed out")

    # earlier nights for the history
    tok=sql("select api_login('4821')->>'token'"); bb=sql("select id from drawers where name='Back Bar'"); fb=sql("select id from drawers where name='Front Bar'")
    for day,dr,body in [(d(-1),bb,'{"short":true,"amount":12.5}'),(d(-1),fb,'{"short":false}'),(d(-3),bb,'{"short":true,"amount":3}')]:
        sql("select api_cash_out('%s','%s','%s'::jsonb,'%s')" % (tok, dr, body, day))
    sql("update cashouts set by_id='kate', by_name='Kate'")
    sql("insert into push_subs (endpoint, staff_id, p256dh, auth, prefs, created_at) select 'https://x/1', id, 'k','a','{\"quiet\":false}', now() - interval '2 days' from staff where name='Aidan'")
    alerts=[x for x in json.loads(sql("select _push_collect()")) if x["tag"]=="cash"]; print("alerts:", [(x["title"], x["body"]) for x in alerts])
    assert alerts[0]["title"]=="3 drawers short"

    a.reload(); a.wait_for_timeout(1500)
    expect(a.locator("#tabCash")).to_have_class(re.compile("has-dot"))
    a.locator("#tabCash").click()
    expect(a.locator(".refill")).to_contain_text("Needs replenishing"); expect(a.locator(".refill .tag")).to_have_text("$21.72")
    expect(a.locator(".refill .cashrow")).to_have_count(3)
    expect(a.locator(".cstat").first).to_contain_text("2"); expect(a.locator(".cstat").nth(1)).to_contain_text("$15.50")
    a.wait_for_timeout(400); a.screenshot(path=OUT+"/s4-manager.png", full_page=True)
    a.locator(".refill .cashrow", has_text="$12.50").get_by_role("button", name="Replenished").click(); a.wait_for_timeout(1200)
    expect(a.locator(".refill .cashrow")).to_have_count(2)
    with a.expect_download() as dl: a.get_by_role("button", name="Download CSV").click()
    csv=open(dl.value.path()).read(); print(csv); assert "Back Bar,Kate,Yes,12.5," in csv and ",Aidan," in csv
    # detail: undo replenished, then mark it from the sheet
    a.locator(".cashday").first.locator(".cashrow", has_text="Back Bar").click()
    expect(a.locator(".sheet .pfacts")).to_contain_text("by Aidan")
    a.get_by_role("button", name="Not replenished after all").click(); a.wait_for_timeout(1200)
    expect(a.locator(".refill .cashrow")).to_have_count(3)
    row(a,"Back Bar").click(); a.wait_for_timeout(500); a.screenshot(path=OUT+"/s5-detail.png")
    a.get_by_role("button", name="Mark replenished").click(); a.wait_for_timeout(1200)
    expect(a.locator(".refill .cashrow")).to_have_count(2)
    a.locator("#tabShifts").click(); a.wait_for_timeout(500)
    expect(a.locator(".feed")).to_contain_text("Aidan replenished the Back Bar drawer")
    expect(a.locator(".bd-row", has_text="Replenish")).to_contain_text("2 drawers · $15.50")
    a.screenshot(path=OUT+"/s6-board.png")
    dk=login(b,"2222","kate-dark","dark"); dk.locator("#tabCash").click(); row(dk,"Back Bar").click(); dk.wait_for_timeout(500)
    dk.screenshot(path=OUT+"/s7-dark.png")
    b.close()
print("errors:", errs)
