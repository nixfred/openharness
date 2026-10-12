import { Camera } from "lucide-react";
import { headers } from "next/headers";
import { redirect } from "next/navigation";
import { APP_PAGE_URL, phoneStoreUrl } from "@/lib/phoneApp";
import { QrCode } from "./QrCode";
import { StoreBadges } from "./StoreBadges";
import styles from "./page.module.css";

export const dynamic = "force-dynamic";

/**
 * `harness.autonomous.ai/app` — the download code for the phone app. A phone's camera opens it, and
 * the server sends it straight to its store by user agent: an iPhone to the App Store, an Android
 * phone to Google Play, each of which opens in the store app. Anything else — a computer, or an iPad
 * asking for the desktop site — lands here: this page's own code to scan, and both stores.
 */
export default async function AppPage() {
  const store = phoneStoreUrl((await headers()).get("user-agent"));
  if (store) redirect(store);
  return (
    <main className={styles.page}>
      <div className={styles.glow} aria-hidden="true" />
      <section className={styles.hero}>
        <div className={styles.copy}>
          <p className={styles.brand}>
            {/* eslint-disable-next-line @next/next/no-img-element -- the site icon, already cached. */}
            <img src="/icon.svg?v=5" alt="" />
            Harness
          </p>
          <p className={styles.eyebrow}>For iPhone and Android</p>
          <h1 className={styles.title}>
            Run your fleet <span className={styles.accent}>from your phone.</span>
          </h1>
          <p className={styles.lede}>
            At the beach. In a taxi. Away from your desk. Your agents keep working — check progress, answer
            questions, and give them their next task, right from your phone.
          </p>
          <StoreBadges />
        </div>
        <div className={styles.scan}>
          <QrCode value={APP_PAGE_URL} label="QR code for harness.autonomous.ai/app" />
          <p className={styles.scanTitle}>
            <Camera size={18} aria-hidden="true" />
            Scan with your phone&apos;s camera
          </p>
          <p className={styles.scanNote}>Opens the App Store or Google Play.</p>
        </div>
      </section>
    </main>
  );
}
