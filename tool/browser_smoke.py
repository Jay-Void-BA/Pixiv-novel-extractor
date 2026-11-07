#!/usr/bin/env python3
"""Real Flutter Web UI + downloads, with original synthetic Pixiv responses.

Optional developer dependency: pip install playwright && playwright install chromium
No credentials, actual Pixiv requests, or browser extensions are used.
"""
import argparse
import json
import re
import sys
import threading
from pathlib import Path
from urllib.parse import parse_qs, urlsplit

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / "freebsd"))
from shiori_server import create_server


def main():
    from playwright.sync_api import sync_playwright, expect
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--browser", help="Optional system Chromium executable")
    parser.add_argument("--screenshots", type=Path, default=ROOT / "build/browser-results")
    args = parser.parse_args()
    args.screenshots.mkdir(parents=True, exist_ok=True)
    server = create_server(ROOT / "build/web")
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()

    def fixture(route):
        path = parse_qs(urlsplit(route.request.url).query)["path"][0]
        if path.endswith("/content_titles"):
            body = [{"id": str(i), "order": i, "title": f"第 {i} 章 · 自编示例", "available": True}
                    for i in range(1, 5)]
        elif "/series/" in path:
            body = {"title": "山间来信 · 自编测试系列", "userName": "Shiori 测试作者", "total": 4,
                    "caption": "浏览器集成测试，非真实 Pixiv 作品。"}
        else:
            i = path.rsplit("/", 1)[1]
            body = {"title": f"第 {i} 章 · 自编示例", "userName": "Shiori 测试作者",
                    "content": f"独立章节标记 CHAPTER_{i}。\n这是一段自行编写的测试正文。"}
        route.fulfill(status=200, content_type="application/json",
                      body=json.dumps({"error": False, "body": body}, ensure_ascii=False))

    try:
        with sync_playwright() as p:
            # Hosted Linux runners do not have a usable hardware GPU. Select
            # Chromium's software WebGL backend explicitly for CanvasKit.
            browser = p.chromium.launch(executable_path=args.browser, headless=True,
                                         args=["--no-sandbox", "--disable-dev-shm-usage",
                                               "--use-angle=swiftshader", "--enable-unsafe-swiftshader"])
            page = browser.new_page(viewport={"width": 1440, "height": 1600}, device_scale_factor=1)
            errors = []
            diagnostics = {"console": [], "failed_requests": [], "http_errors": []}
            page.on("pageerror", lambda e: errors.append(str(e)))
            page.on("console", lambda message: diagnostics["console"].append(
                {"type": message.type, "text": message.text}))
            page.on("requestfailed", lambda request: diagnostics["failed_requests"].append(
                {"url": request.url, "failure": request.failure}))
            page.on("response", lambda response: diagnostics["http_errors"].append(
                {"url": response.url, "status": response.status}) if response.status >= 400 else None)
            page.route("**/api/pixiv?*", fixture)
            # Fail closed if the UI unexpectedly tries to access Pixiv directly.
            page.route("https://*.pixiv.net/**", lambda route: route.abort())
            page.goto(f"http://127.0.0.1:{server.server_port}/")
            try:
                page.locator("flutter-view").wait_for(timeout=60000)
            except Exception:
                diagnostics["page_errors"] = errors
                (args.screenshots / "startup-diagnostics.json").write_text(
                    json.dumps(diagnostics, ensure_ascii=False, indent=2), encoding="utf-8")
                (args.screenshots / "startup.html").write_text(page.content(), encoding="utf-8")
                page.screenshot(path=str(args.screenshots / "startup-failure.png"), full_page=True)
                print(json.dumps(diagnostics, ensure_ascii=False), flush=True)
                raise
            # Flutter exposes this intentionally hidden DOM button for assistive tools.
            page.locator("flt-semantics-placeholder").evaluate("(node)=>node.click()")
            source = page.get_by_role("textbox").first
            source.fill("https://www.pixiv.net/novel/series/123")
            page.get_by_role("button", name="读取作品").click()
            print("Loaded request submitted", flush=True)
            page.get_by_text("山间来信 · 自编测试系列", exact=True).wait_for(timeout=15000)
            page.screenshot(path=str(args.screenshots / "screenshot-desktop.png"), full_page=True)
            expect(page.get_by_text("已选 4 / 4", exact=True)).to_be_visible()
            selection = page.get_by_role("textbox", name=re.compile("范围"))
            # Fill emits one complete input event after focusing the field.
            # Per-key typing can race Flutter's text-editing attachment and
            # lose its first character on a slower hosted runner.
            selection.fill("2,4")
            expect(selection).to_have_value("2,4")
            page.get_by_role("button", name="应用", exact=True).click()
            expect(page.get_by_text("已选 2 / 4", exact=True)).to_be_visible(timeout=10000)
            with page.expect_download() as download:
                page.get_by_role("button", name="导出 TXT", exact=True).click()
            txt = args.screenshots / "selection.txt"
            download.value.save_as(txt)
            print("TXT downloaded", flush=True)
            text = txt.read_text(encoding="utf-8-sig")
            assert "CHAPTER_2" in text and "CHAPTER_4" in text
            assert "CHAPTER_1" not in text and "CHAPTER_3" not in text
            assert text.index("CHAPTER_2") < text.index("CHAPTER_4")
            page.get_by_role("button", name=re.compile("PDF")).first.click()
            print("PDF selected", flush=True)
            page.screenshot(path=str(args.screenshots / "before-pdf.png"), full_page=True)
            with page.expect_download(timeout=60000) as download:
                # Activate Flutter's public accessibility button directly. Its
                # canvas semantics overlay varies in hit testing across engines.
                page.get_by_role("button", name="导出 PDF", exact=True).evaluate("(node)=>node.click()")
            pdf = args.screenshots / "selection.pdf"
            download.value.save_as(pdf)
            print("PDF downloaded", flush=True)
            assert pdf.read_bytes().startswith(b"%PDF-")
            page.set_viewport_size({"width": 390, "height": 1000})
            page.mouse.move(200, 400)
            page.mouse.wheel(0, -2000)
            page.screenshot(path=str(args.screenshots / "screenshot-mobile.png"), full_page=True)
            assert not errors, errors
            browser.close()
        print("PASS: real Flutter UI, range selection, ordered TXT/PDF downloads and mobile viewport; no runtime errors")
    finally:
        server.shutdown()
        server.server_close()
        thread.join()


if __name__ == "__main__": main()
