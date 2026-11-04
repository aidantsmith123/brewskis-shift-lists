"""Who sees which tasks and activity: front of house, back of house, everyone, assigned to one person,
and staff with no role. Run on setup_v22.sh (Jill FOH 1111, Kate FOH 2222, Liam BOH 5555)."""
import sys, subprocess
from playwright.sync_api import sync_playwright, expect
URL="http://127.0.0.1:8099/"
def sql(q): return subprocess.run(["psql","-h","/var/tmp","-p","54329","-U","postgres","-d","bk","-Atc",q],capture_output=True,text=True,check=True).stdout.strip()
sql("insert into staff (id,name,roles) values ('newbie','Newbie','{}') on conflict do nothing; select admin_set_pin('Newbie','1357');")
sql("""insert into tasks (role_id, text, repeat, added_by_name, assignee) values
  ('closing-bartender','Wipe down the taps','once','Aidan',null), ('dishwasher','Fill and test the sanitizer','once','Aidan',null),
  (null,'Restock the merch shelf','once','Aidan',null), (null,'Audit the liquor prices','once','Tom','kate'),
  ('manager','Do the payroll','once','Aidan',null)""")
def login(b, pin):
    pg=b.new_context(viewport={"width":390,"height":844}).new_page(); pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1300); return pg
def done_line(pg):   # "x of y done", read the way a screen reader would (rolling digits count once)
    pg.wait_for_timeout(1100)
    return pg.evaluate("()=>{ const c=document.querySelector('.tn-sum').cloneNode(true); c.querySelectorAll('.rd').forEach(x=>x.remove()); return c.textContent.trim(); }")
def tasks(pg): return sorted(t.split("\n")[0] for t in pg.locator(".task").all_inner_texts())
with sync_playwright() as p:
    b=p.chromium.launch(); errs=[]
    j=login(b,"1111"); j.on("pageerror", lambda e: errs.append(str(e))); print("Jill:", tasks(j))
    assert tasks(j)==["Restock the merch shelf","Wipe down the taps"], tasks(j)
    k=login(b,"2222"); print("Kate:", tasks(k))
    assert tasks(k)==["Audit the liquor prices","Restock the merch shelf","Wipe down the taps"], tasks(k)   # hers by name
    l=login(b,"5555"); print("Liam:", tasks(l))
    assert tasks(l)==["Fill and test the sanitizer","Restock the merch shelf"], tasks(l)
    l.get_by_role("button", name="Check off Fill and test the sanitizer").click(); l.wait_for_timeout(900)
    n=login(b,"1357"); print("Newbie:", tasks(n)); assert tasks(n)==["Restock the merch shelf"], tasks(n)
    a=login(b,"4821"); print("Aidan:", tasks(a))
    # managers see everything, but a task assigned to someone else isn't on their own to-do list: it's folded away
    assert tasks(a)==["Do the payroll","Restock the merch shelf","Wipe down the taps"] and a.get_by_role("button", name="Done · 1").count()==1, tasks(a)
    fold=a.get_by_role("button", name="Assigned to others · 1  ▸"); expect(fold).to_be_visible(); fold.click()
    expect(a.locator(".task", has_text="Audit the liquor prices")).to_contain_text("For Kate")
    a.screenshot(path=sys.argv[1]+"/sides-others.png", full_page=True)
    a.reload(); a.wait_for_timeout(1300)   # stays open on this phone until folded again
    expect(a.locator(".task", has_text="Audit the liquor prices")).to_be_visible()
    a.get_by_role("button", name="Assigned to others · 1  ▾").click(); expect(a.locator(".task", has_text="Audit the liquor prices")).to_have_count(0)
    # ...and Kate's assigned task isn't in Aidan's own count: 4 of his, 1 done (Liam's sanitizer)
    print("Aidan's count:", done_line(a)); assert done_line(a)=="1 of 4 done", done_line(a)
    print("Kate's count:", done_line(k)); assert done_line(k)=="0 of 3 done", done_line(k)
    expect(a.locator(".feed")).to_contain_text("Fill and test the sanitizer")                 # managers see BOH activity
    j.reload(); j.wait_for_timeout(1300)
    assert "Fill and test the sanitizer" not in (j.locator(".feed").inner_text() if j.locator(".feed").count() else "")   # Jill doesn't
    print("ERRORS:", errs); assert not errs; print("SIDES FLOWS PASSED")
