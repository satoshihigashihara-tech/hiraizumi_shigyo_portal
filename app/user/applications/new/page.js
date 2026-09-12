import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import styles from "./page.module.css";

export const metadata = {
  title: "新規申請｜ひらいずみ志業ポータル",
  description: "利用目的に合った申請手続きを選びます。",
};

export default function NewApplicationPage() {
  return (
    <PageShell
      title="新しく申請する"
      description="利用目的を選んでください。利用できる手続きから順にご案内します。"
    >
      <section className={styles.available} aria-labelledby="camp-application-heading">
        <div className={styles.availableCopy}>
          <h2 className={styles.sectionTitle} id="camp-application-heading">
            スパルタキャンプで利用する
          </h2>
          <p className={styles.description}>
            対象者として登録されたキャンプと、職員が設定した利用期間を確認して申請を始めます。
          </p>
        </div>
        <LinkButton
          href="/user/applications/new/camp"
          variant="primary"
          fullWidthOnMobile
        >
          キャンプを選ぶ
        </LinkButton>
      </section>

      <section className={styles.available} aria-labelledby="community-application-heading">
        <div className={styles.availableCopy}>
          <h2 className={styles.sectionTitle} id="community-application-heading">
            地域活動で利用する（個人）
          </h2>
          <p className={styles.description}>
            町内で行う活動の内容と、2日から15日までの利用期間を入力して申請します。
          </p>
        </div>
        <LinkButton href="/user/applications/new/community-activity" variant="primary" fullWidthOnMobile>
          個人申請を始める
        </LinkButton>
      </section>

      <section className={styles.available} aria-labelledby="group-application-heading">
        <div className={styles.availableCopy}>
          <h2 className={styles.sectionTitle} id="group-application-heading">
            地域活動で利用する（団体）
          </h2>
          <p className={styles.description}>
            2人から15人までの団体情報と利用期間を登録し、代表者として申請を始めます。
          </p>
        </div>
        <LinkButton href="/user/groups/new" variant="primary" fullWidthOnMobile>
          団体を作る
        </LinkButton>
      </section>

      <div className={styles.backLink}>
        <LinkButton href="/user/applications" fullWidthOnMobile>
          申請一覧へ戻る
        </LinkButton>
      </div>
    </PageShell>
  );
}
