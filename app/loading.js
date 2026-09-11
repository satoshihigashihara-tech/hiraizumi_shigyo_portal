import PageShell from "@/app/components/PageShell";
import styles from "./Boundary.module.css";

export default function Loading() {
  return (
    <PageShell title="読み込んでいます">
      <div className={styles.loadingPanel} role="status" aria-live="polite">
        <span className={styles.loadingLineShort} aria-hidden="true" />
        <span className={styles.loadingLine} aria-hidden="true" />
        <span>画面を読み込んでいます。しばらくお待ちください。</span>
      </div>
    </PageShell>
  );
}
