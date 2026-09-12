import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import styles from "./page.module.css";

const CAMP_HOME = "/user?mode=camp";

export const metadata = { title: "キャンプ利用｜ひらいずみ志業ポータル", description: "スパルタキャンプ参加者向けのシェアハウス利用案内です。" };

export default function CampPage() {
  return <div className={styles.page}><PageShell audienceMode="camp" title="スパルタキャンプ参加者の方へ" description="シェアハウスの使用許可申請と申請状況の確認ができます。">
    <section className={styles.section}><h2>このサイトでできること</h2><p>対象キャンプの利用期間を確認し、使用許可を申請できます。申請しただけでは宿泊は確定しません。</p></section>
    <section className={styles.section}><h2>対象者と利用条件</h2><ul><li>職員がキャンプ対象者として登録したメールアドレスでログインする方</li><li>職員が設定した固定期間でシェアハウスを利用する方</li></ul><p>キャンプ本体への参加申込みとは別の手続きです。</p></section>
    <section className={styles.section}><h2>使用料</h2><div className={styles.fee}><strong>1人につき1日300円</strong><p>開始日と終了日の両方を含めます。同じ月の上限9,000円は申請ごとに適用します。</p></div></section>
    <section className={styles.section}><h2>必要書類</h2><AlertMessage tone="warning" title="保護者同意書が必要な方がいます"><p>未成年の方および18歳の高校生の方は、申請ごとに保護者同意書が必要です。</p></AlertMessage></section>
    <section className={styles.section}><h2>申請と状況確認</h2><div className={styles.actions}><LinkButton href={`/login?returnTo=${encodeURIComponent(CAMP_HOME)}`} variant="primary" fullWidthOnMobile>ログインして申請へ進む</LinkButton></div></section>
    <section className={styles.section}><h2>利用状況</h2><LinkButton href="/calendar" fullWidthOnMobile>利用状況カレンダーを見る</LinkButton></section>
  </PageShell></div>;
}
