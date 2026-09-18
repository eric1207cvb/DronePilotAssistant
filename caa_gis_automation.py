#!/usr/bin/env python3
"""Open the CAA UAV GIS, locate a place, and enable official airspace layers.

Usage:
    python3 caa_gis_automation.py "新北市板橋區中正里"
    python3 caa_gis_automation.py "25.03509,121.58059" --screenshot caa-result.png

The script only automates the public CAA GIS webpage. It does not make a
flight-legality decision and does not use an API key.
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

from playwright.sync_api import Page, TimeoutError as PlaywrightTimeoutError, sync_playwright


CAA_GIS_URL = (
    "https://dronegis.caa.gov.tw/portal/apps/webappviewer/index.html"
    "?id=807bd21438ba4208b4a7e28569fe41aa"
)


def coordinate(value: str) -> tuple[float, float] | None:
    """Return latitude/longitude when the input is a valid coordinate pair."""
    match = re.fullmatch(r"\s*(-?\d+(?:\.\d+)?)\s*,\s*(-?\d+(?:\.\d+)?)\s*", value)
    if not match:
        return None
    latitude, longitude = map(float, match.groups())
    if not -90 <= latitude <= 90 or not -180 <= longitude <= 180:
        raise ValueError("座標超出範圍，格式應為：緯度,經度")
    return latitude, longitude


def visible(locator) -> bool:
    try:
        return locator.is_visible()
    except Exception:
        return False


def fill_and_search(page: Page, query: str) -> None:
    """Fill the GIS search box and activate the official search action."""
    candidates = page.locator("input")
    search_box = None
    for index in range(min(candidates.count(), 40)):
        item = candidates.nth(index)
        placeholder = item.get_attribute("placeholder") or ""
        if visible(item) and any(word in placeholder for word in ("空域", "經度", "地址")):
            search_box = item
            break
    if search_box is None:
        raise RuntimeError("找不到民航局 GIS 搜尋欄")

    search_box.fill(query)
    search_box.press("Enter")

    # Some versions of the GIS page require the magnifier after Enter.
    for selector in (
        ".jimu-search-button",
        ".searchBtn",
        ".searchButton",
        "button[title*='搜尋']",
        "button[aria-label*='搜尋']",
    ):
        button = page.locator(selector).first
        if visible(button):
            button.click()
            break


def open_activity_airspace(page: Page) -> None:
    """Open the CAA menu and click '載入活動空域' exactly once."""
    # The menu can be created after the map finishes booting.
    for _ in range(30):
        option = page.get_by_text("載入活動空域", exact=True).first
        if visible(option):
            classes = (option.get_attribute("class") or "").lower()
            aria_pressed = (option.get_attribute("aria-pressed") or "").lower()
            if not any(flag in classes for flag in ("active", "selected", "checked", "open")) and aria_pressed != "true":
                option.click()
            return

        # Open the left-side CAA tool menu when the option is still hidden.
        for selector in (".jimu-widget-onscreen-icon", "button[aria-label*='選單']", "[title*='選單']"):
            menu = page.locator(selector).first
            if visible(menu):
                menu.click()
                break
        page.wait_for_timeout(500)
    raise RuntimeError("找不到民航局 GIS『載入活動空域』選項")


def run(query: str, screenshot: Path | None, headed: bool) -> None:
    target = coordinate(query)
    with sync_playwright() as playwright:
        browser = playwright.chromium.launch(headless=not headed)
        page = browser.new_page(viewport={"width": 1280, "height": 900})
        page.goto(CAA_GIS_URL, wait_until="domcontentloaded", timeout=60_000)
        page.wait_for_timeout(4_000)

        # Search through the official GIS control first. This recenters the map
        # and triggers the GIS layer lifecycle after the initial world map.
        fill_and_search(page, query)
        page.wait_for_timeout(5_000)
        open_activity_airspace(page)
        page.wait_for_timeout(8_000)

        if target:
            print(f"已定位：{target[0]:.5f}, {target[1]:.5f}")
        else:
            print(f"已查詢：{query}")
        print("已嘗試開啟：民航局『載入活動空域』")

        if screenshot:
            page.screenshot(path=str(screenshot), full_page=True)
            print(f"已儲存畫面：{screenshot}")

        if headed:
            print("瀏覽器保持開啟；按 Ctrl-C 結束。")
            try:
                page.wait_for_timeout(3_600_000)
            except KeyboardInterrupt:
                pass
        browser.close()


def main() -> int:
    parser = argparse.ArgumentParser(description="自動定位並啟用民航局官方彩色空域圖層")
    parser.add_argument("query", help="地址、地標，或 緯度,經度")
    parser.add_argument("--screenshot", type=Path, help="儲存完成後的全頁截圖")
    parser.add_argument("--headed", action="store_true", help="顯示瀏覽器視窗並保持開啟")
    args = parser.parse_args()
    try:
        run(args.query, args.screenshot, args.headed)
    except (ValueError, RuntimeError, PlaywrightTimeoutError) as error:
        print(f"自動化失敗：{error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
