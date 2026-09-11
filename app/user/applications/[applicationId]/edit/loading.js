import PageShell from "@/app/components/PageShell";
import styles from "./page.module.css";

export default function ApplicationEditLoading() {
  return (
    <PageShell
      title="申請内容を入力"
      description="申請内容を読み込んでいます。"
    >
      <div
        className={styles.loadingCard}
        role="status"
        aria-live="polite"
        aria-busy="true"
      >
        <span className={styles.loadingLine} />
        <span className={styles.loadingLineShort} />
        <span className={styles.loadingField} />
        <span className={styles.loadingField} />
      </div>
    </PageShell>
  );
}
