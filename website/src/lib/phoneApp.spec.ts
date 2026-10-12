// @vitest-environment node
import { readFileSync } from "node:fs";
import { describe, expect, it } from "vitest";
import { APP_STORE_URL, GOOGLE_PLAY_URL, phoneStoreUrl } from "./phoneApp";

const iphone = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Mobile/15E148 Safari/604.1";
const android = "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/130.0.0.0 Mobile Safari/537.36";
const mac = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.0 Safari/605.1.15";

describe("phoneStoreUrl", () => {
  it("sends an iPhone, iPad or iPod to the App Store", () => {
    expect(phoneStoreUrl(iphone)).toBe(APP_STORE_URL);
    expect(phoneStoreUrl("Mozilla/5.0 (iPad; CPU OS 17_0 like Mac OS X)")).toBe(APP_STORE_URL);
    // Chrome and Firefox on iOS name the iPhone too.
    expect(phoneStoreUrl(`${iphone} CriOS/130.0`)).toBe(APP_STORE_URL);
  });

  it("sends an Android phone or tablet to Google Play", () => {
    expect(phoneStoreUrl(android)).toBe(GOOGLE_PLAY_URL);
    expect(phoneStoreUrl("Mozilla/5.0 (Linux; Android 13; SM-X700) AppleWebKit/537.36 Chrome/130.0 Safari/537.36")).toBe(GOOGLE_PLAY_URL);
  });

  it("leaves computers, an iPad asking for the desktop site, and no user agent to the page", () => {
    expect(phoneStoreUrl(mac)).toBeNull();
    expect(phoneStoreUrl("Mozilla/5.0 (Windows NT 10.0; Win64; x64)")).toBeNull();
    expect(phoneStoreUrl("Mozilla/5.0 (X11; Linux x86_64) Chrome/130.0")).toBeNull();
    expect(phoneStoreUrl(null)).toBeNull();
  });

  it("names the same store listings as the desktop app", () => {
    const dart = readFileSync(new URL("../../../desktop/lib/core/phone_app_links.dart", import.meta.url), "utf8");
    expect(dart).toContain(`'${APP_STORE_URL}'`);
    expect(dart).toContain(`'${GOOGLE_PLAY_URL}'`);
  });
});
