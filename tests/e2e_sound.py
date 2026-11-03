"""Sound effects: a wrong number, logging in, checking off (clink, cheers when all done), undo, counting ticks,
Mark order placed, and turning sounds off (remembered). Run on setup_v22.sh."""
import sys, subprocess
from playwright.sync_api import sync_playwright, expect
URL="http://127.0.0.1:8099/"
def sql(q): return subprocess.run(["psql","-h","/var/tmp","-p","54329","-U","postgres","-d","bk","-Atc",q],capture_output=True,text=True,check=True).stdout.strip()
sql("""insert into tasks (role_id, text, repeat, added_by_name) values (null,'Restock the merch shelf','once','Aidan'), (null,'Wipe the menus','once','Aidan');
       insert into items (id, cat_id, name, unit, par, supplier_id) values ('stoli','bar-supplies','Stoli Orange Vodka','bottles',4,'2kj59bzmiz7d0mtorm4h');
       update suppliers set days='{0,1,2,3,4,5,6}', schedule='weekly' where id='2kj59bzmiz7d0mtorm4h';""")
with sync_playwright() as p:
    b=p.chromium.launch(args=["--autoplay-policy=no-user-gesture-required"]); errs=[]
    ctx=b.new_context(viewport={"width":390,"height":844}); pg=ctx.new_page(); pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.add_init_script("window.__played=[]; window.addEventListener('load',()=>{ const real = window.play; window.play = n => { window.__played.push(n); real(n); }; });")
    pg.goto(URL); pg.locator("#intro").click()
    for x in "9999": pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(600)
    for x in "4821": pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); expect(pg.locator("#whoName")).to_have_text("Aidan · Mgr"); pg.wait_for_timeout(800)
    pg.get_by_role("button", name="Check off Restock the merch shelf").click(); pg.wait_for_timeout(700)
    pg.get_by_role("button", name="Check off Wipe the menus").click(); pg.wait_for_timeout(700)
    pg.get_by_role("button", name="Done · 2").click(); pg.get_by_role("button", name="Uncheck Wipe the menus").click(); pg.wait_for_timeout(700)
    pg.locator("#tabInv").click(); pg.locator(".fold-head", has_text="Bar supplies").click()
    pg.locator("button[aria-label='One more Stoli Orange Vodka']").click(); pg.wait_for_timeout(200)
    pg.locator("button[aria-label='One less Stoli Orange Vodka']").click(); pg.wait_for_timeout(900)
    pg.locator(".card", has_text="Penn Beer").get_by_role("button", name="Mark order placed").click(); pg.wait_for_timeout(1200)
    raw = pg.evaluate("window.__played"); played = [x for x in raw if x!="tap"]; print("played:", raw)
    assert raw.count("tap") >= 6, raw                              # keypad digits, tabs, list header…
    assert played[0]=="nope" and played[1]=="ok", played           # wrong number, then logged in
    seg = played[2:5]; assert seg==["clink","cheers","undo"], played  # one done, all done, undo
    i0 = raw.index("clink"); iu = raw.index("undo")
    assert raw[i0-1]!="tap" and raw[i0+1]=="cheers" and raw[i0+2:iu].count("tap")==1, raw   # check-offs play only their own sound (the 1 tap opens Done)
    assert raw[-3:]==["tickUp","tickDown","ok"], raw               # counting and Mark order placed: no tap
    # turning sounds off is remembered
    pg.locator("#settingsBtn").click(); pg.locator("#soundToggle").uncheck(); pg.wait_for_timeout(200)
    assert pg.evaluate("soundOn")==False
    pg.reload(); pg.wait_for_timeout(1200); assert pg.evaluate("soundOn")==False
    print("ERRORS:", errs); assert not errs; print("SOUND FLOWS PASSED")
