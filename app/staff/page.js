import ComingSoon from "@/app/components/ComingSoon";
import PageShell from "@/app/components/PageShell";
import styles from "./page.module.css";

export default function StaffPage() {
  return (
    <PageShell
      title="職員ホーム"
      description="申請、キャンプ、利用状況を確認・管理します。"
    >
      <section className={styles.actions} aria-labelledby="staff-actions-title">
        <h2 id="staff-actions-title">管理メニュー</h2>
        <p>申請、キャンプ、利用状況の各管理画面を順次接続しています。</p>
      </section>
      <ComingSoon
        title="各管理画面を接続中です"
        description="画面が完成するまで、データベースを直接変更しないでください。"
      />
    </PageShell>
  );
}
