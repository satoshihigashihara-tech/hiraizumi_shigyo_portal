import PageShell from "@/app/components/PageShell";
import styles from "../application-view.module.css";

export default function CampApplicationCompleteLoading() {
  return (
    <PageShell title="キャンプ申請の受付結果" description="受付内容を読み込んでいます。">
      <div className={styles.loadingCard} aria-hidden="true">
        <span className={styles.loadingLineShort} />
        <span className={styles.loadingLine} />
        <span className={styles.loadingLineShort} />
      </div>
    </PageShell>
  );
}
