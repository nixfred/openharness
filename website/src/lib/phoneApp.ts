/**
 * The Harness phone app in its stores, and which store a phone's browser belongs to: what `/app`
 * redirects to. The same listings as the desktop app's `desktop/lib/core/phone_app_links.dart`
 * (`phoneApp.spec.ts` checks), so a listing that moves moves everywhere.
 */

export const APP_STORE_URL = "https://apps.apple.com/us/app/harness-like-a-boss/id6812264068";
export const GOOGLE_PLAY_URL = "https://play.google.com/store/apps/details?id=ai.autonomous.harness.android";

/** This page's own address: what its code encodes, so a phone that scans it is sent to its store. */
export const APP_PAGE_URL = "https://harness.autonomous.ai/app";

/**
 * The store for this user agent, or null for anything that is not a phone or tablet it can name.
 * iPadOS Safari asks for desktop sites by default and reports itself as a Mac, which a server cannot
 * tell apart from one: it gets the page with both stores, like a computer.
 */
export function phoneStoreUrl(userAgent: string | null): string | null {
  const agent = (userAgent ?? "").toLowerCase();
  if (/iphone|ipad|ipod/.test(agent)) return APP_STORE_URL;
  if (agent.includes("android")) return GOOGLE_PLAY_URL;
  return null;
}
