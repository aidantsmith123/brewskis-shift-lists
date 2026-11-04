"""Task done notifications (v51): when someone checks off a task a manager added, that manager is told what got
done and who did it. Not the other managers, not for their own check-offs, not twice, not in quiet hours, and not
when they've switched it off. Run on setup_v22.sh."""
import sys, re, json, subprocess
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
def sql(q): return subprocess.run(["psql","-h","/var/tmp","-p","54329","-U","postgres","-d","bk","-Atc",q],capture_output=True,text=True,check=True).stdout.strip()
sql("select admin_set_pin('Tom','8888'); select admin_set_pin('Mandy','7777')")
sql("""insert into tasks (id, role_id, text, repeat, added_by, added_by_name) select 'tA', 'opening-bartender', 'Restock the garnish tray', 'once', id, name from staff where name='Aidan';
       insert into tasks (id, role_id, text, repeat, added_by, added_by_name) select 'tT', 'opening-bartender', 'Cut lemons', 'once', id, name from staff where name='Tom';
       insert into tasks (id, role_id, text, repeat, added_by, added_by_name) select 'tA2', null, 'Check the ice machine', 'once', id, name from staff where name='Aidan';
       insert into push_subs (endpoint, staff_id, p256dh, auth, prefs, created_at)
         select 'https://x/'||name, id, 'k','a','{"quiet":false}', now()-interval '1 day' from staff where name in ('Aidan','Tom','Mandy','Jill')""")
def done_pushes(): return sorted((x["endpoint"].split("/")[-1], x["title"], x["body"]) for x in json.loads(sql("select _push_collect()")) if x["tag"]=="done")
errs=[]
def login(b, pin):
    pg=b.new_context(viewport={"width":390,"height":844}, timezone_id="America/New_York").new_page(); pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1300); return pg
with sync_playwright() as p:
    b=p.chromium.launch()
    j=login(b,"1111")
    j.get_by_role("button", name="Check off Restock the garnish tray").click(); j.wait_for_timeout(900)
    got=done_pushes(); print("after Jill:", got)
    assert got==[("Aidan","Task done ✓","Jill checked off “Restock the garnish tray”")], got   # just Aidan, who added it
    assert done_pushes()==[]                                                                     # not twice
    # each manager hears about their own tasks only
    j.get_by_role("button", name="Check off Cut lemons").click(); j.get_by_role("button", name="Check off Check the ice machine").click(); j.wait_for_timeout(900)
    got=done_pushes(); print("two more:", got)
    assert got==[("Aidan","Task done ✓","Jill checked off “Check the ice machine”"), ("Tom","Task done ✓","Jill checked off “Cut lemons”")], got
    # unchecked and done again: a new notification for the new check-off
    j.get_by_role("button", name=re.compile("^Done · ")).click()
    j.get_by_role("button", name="Uncheck Cut lemons").click(); j.wait_for_timeout(700); assert done_pushes()==[]
    j.get_by_role("button", name="Check off Cut lemons").click(); j.wait_for_timeout(900)
    assert done_pushes()==[("Tom","Task done ✓","Jill checked off “Cut lemons”")]
    # a manager checking off their own task: nothing
    a=login(b,"4821")
    a.get_by_role("button", name="Add task", exact=True).first.click(); a.locator("#newText").fill("Call the beer rep")
    a.locator("form.add").get_by_role("button", name="Add task").click(); a.wait_for_timeout(900)
    a.get_by_role("button", name="Check off Call the beer rep").click(); a.wait_for_timeout(900)
    assert done_pushes()==[]
    a.get_by_role("button", name=re.compile("^Done · ")).click()
    a.get_by_role("button", name="Uncheck Call the beer rep").click(); a.wait_for_timeout(700)
    # quiet hours hold it back; it arrives once they're over
    sql("update push_subs set prefs = '{\"quiet\":true,\"quiet_start\":\"00:00\",\"quiet_end\":\"23:59\"}' where endpoint = 'https://x/Aidan'")
    j.reload(); j.wait_for_timeout(1200)
    j.get_by_role("button", name="Check off Call the beer rep").click(); j.wait_for_timeout(900)
    assert done_pushes()==[]
    sql("update push_subs set prefs = '{\"quiet\":false}' where endpoint = 'https://x/Aidan'")
    assert done_pushes()==[("Aidan","Task done ✓","Jill checked off “Call the beer rep”")]
    # switched off: nothing
    sql("update push_subs set prefs = '{\"quiet\":false,\"done\":false}' where endpoint = 'https://x/Aidan'")
    j.get_by_role("button", name=re.compile("^Done · ")).click()
    j.get_by_role("button", name="Uncheck Call the beer rep").click(); j.wait_for_timeout(700)
    j.get_by_role("button", name="Check off Call the beer rep").click(); j.wait_for_timeout(900)
    assert done_pushes()==[]
    print("ERRORS:", errs); assert not errs; print("TASK DONE FLOWS PASSED")
