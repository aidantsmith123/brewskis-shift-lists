import sys, psycopg
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
db=psycopg.connect("host=/var/tmp port=54329 user=postgres dbname=bk", autocommit=True)
db.execute("update items set supplier_id = null where cat_id='liquor'")
db.execute("update items set supplier_id = '2kj59bzmiz7d0mtorm4h' where id='l10'")   # Jameson stays with Penn Beer
with sync_playwright() as p:
    b=p.chromium.launch(); errs=[]
    pg=b.new_context(viewport={"width":390,"height":844}).new_page(); pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL); pg.locator("#intro").click()
    for x in "4821": pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); expect(pg.locator("#whoName")).to_have_text("Aidan · Mgr")
    pg.locator("#tabInv").click()
    expect(pg.locator(".card", has_text="No supplier set")).to_contain_text("Stoli Orange Vodka")
    pg.get_by_role("button", name="Edit lists & pars").click()
    pg.locator("#nsName").fill("PLCB"); pg.locator("#nsDay4").click(); pg.get_by_role("button", name="Add supplier").click(); pg.wait_for_timeout(800)
    pg.locator(".fold-head", has_text="Liquor").click()
    pg.locator("#lsup-liquor").locator("xpath=following-sibling::div[1]").get_by_role("radio", name="PLCB", exact=True, include_hidden=True).dispatch_event("click"); expect(pg.get_by_text("Liquor now orders from PLCB")).to_be_visible()
    expect(pg.locator(".listsup")).to_contain_text("except 1 item")
    expect(pg.locator("#es-l1 option").first).to_have_text("List default (PLCB)")
    pg.screenshot(path=OUT+"/ls1-edit.png", full_page=False)
    pg.get_by_role("button", name="Done editing").click()
    plcb = pg.locator(".card", has_text="PLCB")
    expect(plcb).to_contain_text("Stoli Orange Vodka"); expect(plcb).not_to_contain_text("Jameson")
    expect(pg.locator(".card", has_text="Penn Beer")).to_contain_text("Jameson")
    expect(pg.locator(".card", has_text="No supplier set")).not_to_contain_text("Stoli")
    pg.screenshot(path=OUT+"/ls2-orders.png", full_page=True)
    # notification count uses the list default too
    n = db.execute("select e->>'body' from jsonb_array_elements(_push_collect(now())) e limit 1").fetchall()
    sid = db.execute("select id from suppliers where name='PLCB'").fetchone()[0]
    low = db.execute("select count(*) from items i join counts c on c.item_id=i.id join invcats ic on ic.id=i.cat_id where coalesce(i.supplier_id, ic.supplier_id)=%s and c.on_hand < i.par", (sid,)).fetchone()[0]
    print("PLCB items below par (server):", low)
    # staff don't see supplier info
    pj=b.new_context(viewport={"width":390,"height":844}).new_page(); pj.goto(URL); pj.locator("#intro").click()
    for x in "1111": pj.get_by_role("button", name=x, exact=True).click()
    pj.get_by_role("button", name="Log in").click(); pj.wait_for_timeout(1200); pj.locator("#tabInv").click(); pj.locator(".fold-head", has_text="Liquor").click()
    assert pj.get_by_text("PLCB").count()==0 and pj.evaluate("D().invcats.every(c=>c.supplier_id==null)")
    print("ERRORS:", errs); print("LIST SUPPLIER FLOWS PASSED")
