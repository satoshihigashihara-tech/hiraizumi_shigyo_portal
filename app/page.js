import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import styles from "./page.module.css";

export const metadata = { description: "平泉町志業シェアハウスの利用目的に合う入口を選びます。" };

export default function Home() {
  return <div className={styles.page}><PageShell
    title="平泉町志業シェアハウスの利用区分を選ぶ"
    description="利用目的に合う入口を選んでください。申請した時点では利用は確定しません。"
  >
    <div className={styles.choices}>
      <section className={styles.choice} aria-labelledby="camp-choice"><div>
        <h2 id="camp-choice">スパルタキャンプに参加する方</h2>
        <p>スパルタキャンプ参加者としての利用申請、申請状況の確認を行います。</p>
      </div><LinkButton href="/camp" variant="primary" fullWidthOnMobile>キャンプ利用へ進む</LinkButton></section>
      <section className={styles.choice} aria-labelledby="fieldwork-choice"><div>
        <h2 id="fieldwork-choice">大学・学生団体でフィールドワークを行う方</h2>
        <p>団体での利用内容、利用期間、予定人数を登録し、参加者を招待する方はこちらです。</p>
      </div><LinkButton href="/user?mode=fieldwork" variant="primary" fullWidthOnMobile>団体での利用へ進む</LinkButton></section>
    </div>
    <p className={styles.help}>職員から案内された利用者情報でログインしてください。ログイン済みの方も、利用目的に合う入口から進んでください。</p>
    <div className={styles.calendar}><LinkButton href="/calendar" fullWidthOnMobile>利用状況カレンダーを見る</LinkButton></div>
  </PageShell></div>;
}
