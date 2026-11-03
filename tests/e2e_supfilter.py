import sys
from playwright.sync_api import sync_playwright, expect
import subprocess
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
P,M,O="2kj59bzmiz7d0mtorm4h","i6bygvn88t2gj7x9dn3b","eabuqsvdlr9o0obogv06"
rows=[("p%d"%i,"bar-supplies","Bud Light case %d"%i if i<3 else "Penn item %d"%i,P) for i in range(6)]+[("m%d"%i,"paper-products","Muller item %d"%i,M) for i in range(4)]+\
     [("o%d"%i,"bar-supplies","Coors item %d"%i,O) for i in range(2)]+[("n0","paper-products","Straws",None)]
vals=",".join("('%s','%s','%s','cases',2,%s)"%(a,b,c,("'%s'"%d) if d else "null") for a,b,c,d in rows)
subprocess.run(["psql","-h","/var/tmp","-p","54329","-U","postgres","-d","bk","-qc","delete from items; insert into items (id,cat_id,name,unit,par,supplier_id) values "+vals],check=True)
def login(b, pin):
    pg=b.new_context(viewport={"width":390,"height":844}).new_page(); pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1200); pg.locator("#tabInv").click(); return pg
with sync_playwright() as p:
    b=p.chromium.launch(); errs=[]
    pg=login(b,"4821"); pg.on("pageerror", lambda e: errs.append(str(e)))
    chips = pg.locator(".supchips .chip").all_inner_texts(); print("chips:", chips)
    assert chips[0]=="All suppliers" and {"Origlio","Penn","Muller"} <= set(chips), chips
    pg.locator(".supchips").get_by_role("button", name="Penn").click()
    heads = pg.locator(".fold-head").all_inner_texts(); print("lists shown:", [h.replace("\n"," ") for h in heads])
    assert pg.locator(".item").count()==6 and pg.locator(".item", has_text="Coors").count()==0
    pg.screenshot(path=OUT+"/sf1-penn.png", full_page=False)
    pg.locator("#invSearch").fill("bud light"); n=pg.locator(".item").count(); print("penn + 'bud light':", n); assert n==3
    pg.locator("#invSearch").fill(""); pg.locator(".supchips").get_by_role("button", name="Muller").click()
    assert pg.locator(".item").count()==4
    pg.get_by_role("button", name="Edit lists & pars").click(); assert pg.locator(".item.edit").count()==4      # works while editing pars
    pg.get_by_role("button", name="Done editing").click(); pg.locator(".supchips").get_by_role("button", name="All suppliers").click()
    assert pg.locator(".item").count()==0                                                                      # back to closed lists
    j=login(b,"1111"); assert j.locator(".supchips").count()==0                                               # staff don't get it
    print("ERRORS:", errs); print("SUPPLIER FILTER PASSED")
