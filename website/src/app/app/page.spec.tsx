import { render, screen } from "@testing-library/react";
import { beforeEach, describe, expect, it, vi } from "vitest";
import { APP_STORE_URL, GOOGLE_PLAY_URL } from "@/lib/phoneApp";

const mocks = vi.hoisted(() => ({ userAgent: "", redirect: vi.fn((url: string) => { throw new Error(`redirect ${url}`); }) }));
vi.mock("next/headers", () => ({ headers: async () => new Headers({ "user-agent": mocks.userAgent }) }));
vi.mock("next/navigation", () => ({ redirect: mocks.redirect }));

import AppPage from "./page";

beforeEach(() => { mocks.redirect.mockClear(); });

describe("/app — the phone app's download code", () => {
  it("sends an iPhone to the App Store and an Android phone to Google Play", async () => {
    mocks.userAgent = "Mozilla/5.0 (iPhone; CPU iPhone OS 18_0 like Mac OS X)";
    await expect(AppPage()).rejects.toThrow(`redirect ${APP_STORE_URL}`);
    mocks.userAgent = "Mozilla/5.0 (Linux; Android 14; Pixel 8) Chrome/130.0 Mobile";
    await expect(AppPage()).rejects.toThrow(`redirect ${GOOGLE_PLAY_URL}`);
  });

  it("offers a computer this page's code to scan and both stores, instead of a dead end", async () => {
    mocks.userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7)";
    render(await AppPage());
    expect(mocks.redirect).not.toHaveBeenCalled();
    expect(screen.getByRole("heading", { name: "Run your fleet from your phone." })).toBeInTheDocument();
    expect(screen.getByRole("img", { name: "QR code for harness.autonomous.ai/app" })).toBeInTheDocument();
    expect(screen.getByRole("link", { name: "Download on the App Store" })).toHaveAttribute("href", APP_STORE_URL);
    expect(screen.getByRole("link", { name: "Get it on Google Play" })).toHaveAttribute("href", GOOGLE_PLAY_URL);
  });
});
