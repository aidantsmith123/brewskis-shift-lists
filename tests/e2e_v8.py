import sys
from playwright.sync_api import sync_playwright, expect
OUT=sys.argv[1]; URL="http://127.0.0.1:8099/"
with sync_playwright() as p:
    b=p.chromium.launch(); errs=[]
    ctx=b.new_context(viewport={"width":390,"height":844}, color_scheme="dark", timezone_id="America/New_York")
    pg=ctx.new_page(); pg.on("pageerror", lambda e: errs.append(str(e)))
    pg.goto(URL)
    for x in "4821": pg.get_by_role("button", name=x, exact=True).click()
    pg.get_by_role("button", name="Log in").click(); expect(pg.locator("#whoName")).to_have_text("Aidan · Mgr")
    pg.locator("#tabInv").click()
    orders = pg.locator(".fold-head", has_text="Order deadlines")
    expect(orders).to_have_attribute("aria-expanded","true")                     # open by default
    liquor = pg.locator(".fold-head", has_text="Liquor")
    expect(liquor).to_have_attribute("aria-expanded","false"); expect(liquor).to_contain_text("2 below par")
    expect(pg.get_by_text("Grey Goose Vodka")).to_have_count(0)                  # lists start closed
    pg.screenshot(path=OUT+"/v8-1-closed.png", full_page=True)
    orders.click(); expect(orders).to_have_attribute("aria-expanded","false"); expect(orders).to_contain_text("to place")
    liquor.click(); expect(pg.get_by_text("Grey Goose Vodka")).to_be_visible()
    # remembered after reopening the app
    pg.reload(); pg.locator("#tabInv").click()
    expect(pg.locator(".fold-head", has_text="Liquor")).to_have_attribute("aria-expanded","true")
    expect(pg.locator(".fold-head", has_text="Order deadlines")).to_have_attribute("aria-expanded","false")
    pg.locator(".fold-head", has_text="Liquor").click()                           # close it again
    # search
    pg.locator("#invSearch").fill("stoli")
    expect(pg.locator(".item")).to_have_count(5); expect(pg.locator(".fold-head", has_text="Liquor")).to_contain_text("5 matches")
    expect(pg.locator(".fold-head", has_text="Bar supplies")).to_have_count(0)
    pg.locator("#invSearch").fill("stoli rasp"); expect(pg.locator(".item")).to_have_count(1)
    pg.locator("#invSearch").fill("lime"); expect(pg.locator(".item", has_text="Limes")).to_be_visible()
    pg.locator("button[aria-label='One more Limes']").click(); pg.wait_for_timeout(1200)
    expect(pg.locator("#cnt-limes")).to_have_value("3")                           # counting works from search results
    pg.locator("#invSearch").fill("stoli"); pg.get_by_role("button", name="Needs ordering").click()
    expect(pg.locator(".item")).to_have_count(1); expect(pg.locator(".item", has_text="Stoli Orange")).to_be_visible()
    pg.screenshot(path=OUT+"/v8-2-search.png", full_page=True)
    pg.locator("#invSearch").fill("zzz"); expect(pg.get_by_text("No items match")).to_be_visible()
    pg.get_by_role("button", name="Clear search").click(); pg.get_by_role("button", name="All items").click()
    expect(pg.locator(".fold-head", has_text="Liquor")).to_have_attribute("aria-expanded","false")   # back to how it was
    # edit mode: search finds items to edit
    pg.get_by_role("button", name="Edit lists & pars").click()
    pg.locator("#invSearch").fill("tito"); expect(pg.locator(".item.edit")).to_have_count(1)
    pg.locator(".item.edit input[id^='ep-']").fill("10"); pg.locator(".item.edit input[id^='ep-']").press("Tab"); pg.wait_for_timeout(1200)
    pg.get_by_role("button", name="Done editing").click(); pg.locator("#invSearch").fill("tito")
    expect(pg.locator(".item", has_text="Tito")).to_contain_text("Par 10")
    pg.screenshot(path=OUT+"/v8-3-edit.png", full_page=True)
    print("ERRORS:", errs); print("V8 FLOWS PASSED")
