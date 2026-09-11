import LinkButton from "@/app/components/LinkButton";
import styles from "@/app/Boundary.module.css";

export default function StaffNotFound() {
  return (
    <main className={styles.main}>
      <section className={styles.card}>
        <p className={styles.eyebrow}>404</p>
        <h1>職員用の情報が見つかりません</h1>
        <p className={styles.description}>
          URLが間違っているか、対象が削除・変更されています。職員ホームからもう一度お探しください。
        </p>
        <div className={styles.actions}>
          <LinkButton href="/staff" variant="primary">職員ホームへ戻る</LinkButton>
          <LinkButton href="/">トップへ戻る</LinkButton>
        </div>
      </section>
    </main>
  );
}
