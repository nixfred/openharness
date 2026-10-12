import qrcode from "qrcode-generator";
import styles from "./page.module.css";

/** One path of every dark module, so the code draws as a single crisp shape at any size. */
function modulesPath(value: string): { size: number; path: string } {
  // High correction: the Harness mark covers the centre and the code must still read.
  const qr = qrcode(0, "H");
  qr.addData(value);
  qr.make();
  const size = qr.getModuleCount();
  let path = "";
  for (let row = 0; row < size; row++)
    for (let col = 0; col < size; col++) if (qr.isDark(row, col)) path += `M${col} ${row}h1v1h-1z`;
  return { size, path };
}

/** A QR code for [value], rendered on the server with no script, the Harness mark at its centre. */
export function QrCode({ value, label }: { value: string; label: string }) {
  const { size, path } = modulesPath(value);
  return (
    <div className={styles.qr}>
      <svg viewBox={`0 0 ${size} ${size}`} role="img" aria-label={label} shapeRendering="crispEdges">
        <path d={path} fill="currentColor" />
      </svg>
      {/* eslint-disable-next-line @next/next/no-img-element -- a fixed 18% of the code, never optimised. */}
      <img className={styles.qrMark} src="/icon.svg?v=5" alt="" />
    </div>
  );
}
