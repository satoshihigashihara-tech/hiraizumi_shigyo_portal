import PageShell from "@/app/components/PageShell";
import styles from "./application-view.module.css";

export default function CampApplicationDetailLoading() {
  return (
    <PageShell title="キャンプ申請詳細" description="申請内容を読み込んでいます。">
      <div className={styles.loadingCard} aria-hidden="true">
        <span className={styles.loadingLineShort} />
        <span className={styles.loadingLine} />
        <span className={styles.loadingLineShort} />
      </div>
    </PageShell>
  );
}
