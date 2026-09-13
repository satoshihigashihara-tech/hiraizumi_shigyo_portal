import Link from "next/link";
import ShareHouseHero from "./components/ShareHouseHero";
import styles from "./page.module.css";

export const metadata = {
  title: "ひらいずみ志業ポータル｜申請から利用までをひとつに",
  description: "平泉町志業シェアハウスの利用申請、審査状況、部屋、料金を確認できるポータルです。",
};

export default function Home() {
  return <div className={styles.page}>
    <section className={styles.hero} aria-labelledby="hero-title">
      <ShareHouseHero>
        <div className={styles.heroCopy}>
          <h1 id="hero-title"><span className={styles.headlineOpening}><span>平泉で始める、</span><span>その一歩を。</span></span><span>手続きで<span className={styles.heroEmphasis}>止めない。</span></span></h1>
        </div>
      </ShareHouseHero>
      <div className={styles.heroDetails}>
        <p className={styles.lead}>志業シェアハウスの申請から審査、部屋、料金の確認までを、ひとつの画面で。</p>
        <div className={styles.heroActions}>
          <Link className={styles.primaryAction} href="/welcome-user">申請を始める</Link>
          <Link className={styles.secondaryAction} href="/calendar">空き状況を見る</Link>
        </div>
      </div>
    </section>

    <p className={styles.prototypeNotice}>このサイトは自主制作の試作版です。平泉町の公式運営サービスではありません。</p>

    <section className={styles.serviceIntroduction} aria-labelledby="service-name">
      <h2 id="service-name">ひらいずみ志業ポータル</h2>
      <p>
        <span>平泉町志業シェアハウスの利用申請から審査、部屋、料金の確認までを、</span>
        <span>ひとつの場所で進められるサービスです。</span>
        <span>スパルタキャンプへの参加と、大学・学生団体によるフィールドワークを支えます。</span>
      </p>
    </section>

    <section className={styles.journey} aria-labelledby="journey-title">
      <h2 id="journey-title">申請から利用まで</h2>
      <ol>
        <li><h3>申請する</h3><p>利用目的と日程を入力し、内容を確認して提出します。</p></li>
        <li><h3>審査を待つ</h3><p>提出後の状態と、修正が必要な場合の案内を確認します。</p></li>
        <li><h3>準備を確認する</h3><p>許可後の部屋、料金、納付状況を本人の画面で確認します。</p></li>
        <li><h3>利用する</h3><p>職員と同じ申請情報をもとに、入退去まで記録します。</p></li>
      </ol>
    </section>

    <section className={styles.assurance} aria-labelledby="assurance-title">
      <h2 id="assurance-title">見える情報を、必要な人だけに</h2>
      <div className={styles.assuranceGrid}>
        <div><h3>利用する方</h3><p>自分の申請、料金、部屋、手続きの状態を確認できます。</p></div>
        <div><h3>職員</h3><p>権限を確認したうえで、審査から利用管理までを進めます。</p></div>
      </div>
    </section>

  </div>;
}
