import sys, re, json, subprocess, datetime
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"; errs=[]
def sql(q): return subprocess.run(["psql","-h","/var/tmp","-p","54329","-U","postgres","-d","bk","-Atc",q],capture_output=True,text=True,check=True).stdout.strip()
def login(b, pin, who, scheme="light"):
    ctx=b.new_context(viewport={"width":390,"height":844}, timezone_id="America/New_York", color_scheme=scheme, accept_downloads=True)
    pg=ctx.new_page(); pg.on("pageerror", lambda e: errs.append(who+": "+str(e)))
    pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1400); return pg
sql("select admin_set_pin('Mandy','7777'); select admin_set_pin('Brian','3333'); select admin_set_pin('Tom','8888')")
yday=sql("select _shift_day()-1")
with sync_playwright() as p:
    b=p.chromium.launch()
    a=login(b,"4821","aidan")
    expect(a.locator(".bd-row", has_text="Daily cash")).to_be_visible()
    a.locator(".bd-row", has_text="Daily cash").click(); a.wait_for_timeout(500)
    expect(a.locator("#dcDay")).to_have_value(yday)
    a.locator("#dcSales").fill("795")
    for i,(w,amt) in enumerate([("Server drawer","24"),("Mark","551"),("Kyle","502"),("Kevin","450")]):
        if i: a.get_by_role("button", name="+ Add payout").click()
        a.locator(".dcrow").nth(i).locator(".dcwho").fill(w); a.locator(".dcrow").nth(i).locator(".dcamt").fill(amt)
    expect(a.locator(".sheet fieldset .hint b")).to_have_text("$1,527")
    a.get_by_role("button", name="Save and send").click(); expect(a.locator(".sheet .loginerr")).to_have_text("Enter the COH.")
    a.locator("#dcLeft").fill("1390"); a.locator("#dcNote").fill("Paid the band")
    a.wait_for_timeout(300); a.screenshot(path=OUT+"/d1-form.png")
    a.get_by_role("button", name="Save and send").click(); a.wait_for_timeout(1500)
    card=a.locator("#dailyCash"); expect(card).to_contain_text("Only Aidan, Tom and Mandy can see this.")
    expect(card.locator(".cstat").nth(0)).to_contain_text("$795"); expect(card.locator(".cstat").nth(1)).to_contain_text("$1,527"); expect(card.locator(".cstat").nth(2)).to_contain_text("COH")
    expect(card.locator(".dcpays li")).to_have_count(4)
    a.wait_for_timeout(400); a.screenshot(path=OUT+"/d2-card.png", full_page=True)
    a.locator("#tabShifts").click(); expect(a.locator(".bd-row", has_text="Daily cash")).to_have_count(0)
    expect(a.locator("main")).not_to_contain_text("795")
    # notifications: Tom and Mandy only
    sql("insert into push_subs (endpoint, staff_id, p256dh, auth, prefs, created_at) select 'https://x/'||name, id, 'k','a','{\"quiet\":false}', now()-interval '1 day' from staff where name in ('Aidan','Tom','Mandy','Brian')")
    who=sorted(x["endpoint"].split("/")[-1] for x in json.loads(sql("select _push_collect()")) if x["tag"]=="dcash"); print("notified:", who); assert who==["Mandy","Tom"]
    # Tom edits it (payee suggestions, removing a row)
    t=login(b,"8888","tom"); t.locator("#tabCash").click(); t.locator("#dailyCash .dclatest").click(); t.wait_for_timeout(400)
    expect(t.locator("#dcPayees option")).to_have_count(4)
    t.locator(".dcrow").nth(0).locator(".dcdel").click(); expect(t.locator(".sheet fieldset .hint b")).to_have_text("$1,503")
    t.get_by_role("button", name="Save changes").click(); t.wait_for_timeout(1300)
    expect(t.locator("#dailyCash .cstat").nth(1)).to_contain_text("$1,503")
    al=[x for x in json.loads(sql("select _push_collect()")) if x["tag"]=="dcash"]; print([(x["endpoint"],x["title"]) for x in al])
    assert sorted(x["endpoint"].split("/")[-1] for x in al)==["Aidan","Mandy"] and al[0]["title"].startswith("Daily cash updated")
    # Brian: a manager, but not on the list
    br=login(b,"3333","brian"); br.locator("#tabCash").click(); br.wait_for_timeout(400)
    expect(br.locator("#dailyCash")).to_have_count(0); expect(br.locator(".bd-row", has_text="Daily cash")).to_have_count(0)
    assert br.evaluate("(S.data.daily_cash||[]).length")==0
    err=br.evaluate("call('api_daily_cash_save',{p_day:shiftDay(), p_data:{cash_sales:1,left_over:1}}).then(()=>'saved',e=>e.code)"); print("brian save:", err); assert err=="not_allowed"
    br.screenshot(path=OUT+"/d3-brian.png")
    # staff
    k=login(b,"2222","kate"); assert k.evaluate("(S.data.daily_cash||[]).length")==0
    with a.expect_download() as dl:
        a.locator("#tabCash").click(); a.get_by_role("button", name="Download CSV").click()
    csv=open(dl.value.path()).read(); print(csv); assert "Mark 551; Kyle 502; Kevin 450" in csv
    dk=login(b,"7777","mandy-dark","dark"); dk.locator("#tabCash").click(); dk.wait_for_timeout(500); dk.screenshot(path=OUT+"/d4-dark.png")
    b.close()
print("errors:", errs)
