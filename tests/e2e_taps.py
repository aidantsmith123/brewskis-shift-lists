import sys
from playwright.sync_api import sync_playwright, expect
import subprocess
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
# its own kegs (run on reset_db.sh)
subprocess.run(["psql","-h","/var/tmp","-p","54329","-U","postgres","-d","bk","-qc","""
  insert into invcats (id,name,sort) values ('kegs','Kegs',-1) on conflict do nothing;
  insert into items (id,cat_id,name,unit,par) values ('kc','kegs','Coors Light 1/2','kegs',3),('kg','kegs','Guinness 50L','kegs',2),
    ('kb','kegs','Bud Light 1/2','kegs',3),('ky','kegs','Yuengling 1/2','kegs',3) on conflict do nothing;"""], check=True)
def login(b, pin):
    pg=b.new_context(viewport={"width":390,"height":844}).new_page(); pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1200); pg.locator("#tabInv").click(); return pg
with sync_playwright() as p:
    b=p.chromium.launch(); errs=[]
    j=login(b,"1111"); j.on("pageerror", lambda e: errs.append(str(e)))
    expect(j.locator(".tapstrip")).to_contain_text("Nothing marked on tap")
    j.locator(".fold-head", has_text="Kegs").click()
    for name in ["Coors Light 1/2","Guinness 50L","Bud Light 1/2"]:
        j.locator(".item", has_text=name).get_by_role("button", name="Put on tap").click(); j.wait_for_timeout(700)
    expect(j.locator(".fold-head", has_text="Kegs")).to_contain_text("3 on tap")
    expect(j.locator(".tapstrip")).to_contain_text("3 beers on tap")
    j.screenshot(path=OUT+"/t1-staff.png", full_page=False)
    # kick Bud Light (needs a second tap)
    row = j.locator(".item", has_text="Bud Light 1/2"); row.get_by_role("button", name="On tap").click(); row.get_by_role("button", name="Tap again: kicked").click(); j.wait_for_timeout(800)
    expect(j.locator(".tapstrip")).to_contain_text("2 beers on tap")
    # manager names Guinness for the board
    a=login(b,"4821"); a.on("pageerror", lambda e: errs.append("aidan "+str(e)))
    a.get_by_role("button", name="Edit lists & pars").click(); a.locator("#invSearch").fill("guinness 50")
    gid = a.locator("input[id^='tl-']").first.get_attribute("id")
    a.locator("#"+gid).fill("Guinness Draught"); a.locator("#"+gid).press("Tab"); a.wait_for_timeout(600)
    a.locator("#tn-"+gid[3:]).fill("Irish stout · 4.2%"); a.locator("#tn-"+gid[3:]).press("Tab"); a.wait_for_timeout(900)
    a.get_by_role("button", name="Done editing").click(); a.locator("#invSearch").fill("")
    a.get_by_role("button", name="Board").click(); expect(a.get_by_role("link", name="Open board")).to_be_visible(); a.wait_for_timeout(800)
    a.screenshot(path=OUT+"/t2-sheet.png", full_page=False)
    # the public board, no login
    for (w,h,tag) in [(1920,1080,"tv"),(390,844,"phone")]:
        bp=b.new_context(viewport={"width":w,"height":h}).new_page(); bp.on("pageerror", lambda e: errs.append("board "+str(e)))
        bp.goto(URL+"taps.html"); bp.wait_for_timeout(1200)
        names=bp.locator(".tap .name").all_inner_texts(); print(tag, "board:", names, "|", bp.locator("#count").inner_text())
        assert [n.upper() for n in names]==["COORS LIGHT","GUINNESS DRAUGHT"], names
        expect(bp.locator(".tap", has_text="Guinness Draught")).to_contain_text("Irish stout · 4.2%")
        bp.screenshot(path=OUT+f"/t3-board-{tag}.png")
    a.locator("#sheet").press("Escape") if False else None
    a.goto(URL); a.wait_for_timeout(1200)
    expect(a.locator(".feed")).to_contain_text("put Coors Light 1/2 on tap"); expect(a.locator(".feed")).to_contain_text("marked Bud Light 1/2 kicked")
    print("ERRORS:", errs); print("ON TAP FLOWS PASSED")
