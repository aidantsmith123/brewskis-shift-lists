"""Daily cash, earlier days (v52): only the 3 most recent earlier days show; "Show N more days" opens the rest,
"Show fewer" folds them again, and the list starts folded each time the app opens. Run on setup_v22.sh."""
import sys, subprocess
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"; errs=[]
def sql(q): return subprocess.run(["psql","-h","/var/tmp","-p","54329","-U","postgres","-d","bk","-Atc",q],capture_output=True,text=True,check=True).stdout.strip()
# ten days of numbers: the newest is the big card, nine are earlier days
sql("""insert into daily_cash (day, cash_sales, payouts_total, left_over, by_name)
       select _shift_day() - g, 500 + g, 100, 400 + g, 'Aidan' from generate_series(1, 10) g""")
def login(b, pin):
    pg=b.new_context(viewport={"width":390,"height":844}, timezone_id="America/New_York").new_page(); pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL); pg.locator("#intro").click()
    for x in pin: pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); pg.wait_for_timeout(1300); return pg
with sync_playwright() as p:
    b=p.chromium.launch()
    a=login(b,"4821"); a.locator("#tabCash").click(); a.wait_for_timeout(500)
    rows=a.locator("#dailyCash .cashrow")
    expect(rows).to_have_count(3)
    expect(rows.nth(0)).to_contain_text("Sales $502")          # newest earlier day first
    more=a.get_by_role("button", name="Show 6 more days")
    expect(more).to_have_attribute("aria-expanded", "false")
    a.locator("#dailyCash").screenshot(path=OUT+"/dcfold1.png")
    more.click(); expect(rows).to_have_count(9)
    expect(rows.nth(8)).to_contain_text("Sales $510")
    fewer=a.get_by_role("button", name="Show fewer"); expect(fewer).to_have_attribute("aria-expanded", "true")
    fewer.click(); expect(rows).to_have_count(3)
    # opened, then the app reopens: folded again
    a.get_by_role("button", name="Show 6 more days").click(); expect(rows).to_have_count(9)
    a.reload(); a.wait_for_timeout(1300); a.locator("#tabCash").click(); a.wait_for_timeout(500)
    expect(rows).to_have_count(3)
    # a row still opens that day's numbers
    rows.nth(1).click(); a.wait_for_timeout(400); expect(a.locator("#dcSales")).to_have_value("503")
    # with 3 or fewer earlier days there's no button
    sql("delete from daily_cash where day < _shift_day() - 4")
    a.reload(); a.wait_for_timeout(1300); a.locator("#tabCash").click(); a.wait_for_timeout(500)
    expect(rows).to_have_count(3); expect(a.locator("#dailyCash .dcmore")).to_have_count(0)
    print("ERRORS:", errs); assert not errs; print("DAILY CASH FOLD PASSED")
