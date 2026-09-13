import Image from "next/image";
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
      <div className={styles.heroCopy}>
        <p className={styles.eyebrow}>ひらいずみ志業ポータル</p>
        <h1 id="hero-title"><span>平泉で始める、</span><span>その一歩を。</span><span className={styles.heroEmphasis}>手続きで止めない。</span></h1>
        <p className={styles.lead}>志業シェアハウスの申請から審査、部屋、料金の確認までを、ひとつの画面で。</p>
        <div className={styles.heroActions}>
          <Link className={styles.primaryAction} href="/welcome-user">申請を始める</Link>
          <Link className={styles.secondaryAction} href="/calendar">空き状況を見る</Link>
        </div>
      </div>
      <ShareHouseHero />
    </section>

    <p className={styles.prototypeNotice}>このサイトは自主制作の試作版です。平泉町の公式運営サービスではありません。</p>

    <section className={styles.introduction} aria-labelledby="intro-title">
      <div className={styles.introCopy}>
        <h2 id="intro-title">参加のかたちに合う入口から</h2>
        <p>スパルタキャンプ参加者と、大学・学生団体のフィールドワーク。それぞれに必要な手続きへ迷わず進めます。</p>
      </div>
      <div className={styles.screenFrame}>
        <Image
          src="/landing/application-choices.png"
          alt="スパルタキャンプとフィールドワークの利用入口を選ぶ画面"
          width={1280}
          height={720}
          loading="eager"
          sizes="(max-width: 767px) 100vw, 58vw"
        />
      </div>
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

    <section className={styles.availability} aria-labelledby="availability-title">
      <div className={styles.calendarFrame}>
        <Image
          src="/landing/availability-calendar.png"
          alt="申請可能、利用不可、受付開始前を示す利用状況カレンダー"
          width={1280}
          height={720}
          sizes="(max-width: 767px) 100vw, 54vw"
        />
      </div>
      <div className={styles.availabilityCopy}>
        <h2 id="availability-title">空き状況は、ログイン前に</h2>
        <p>公開カレンダーには個人情報を表示せず、申請できる日と利用できない日だけを示します。</p>
        <Link className={styles.textLink} href="/calendar">利用状況カレンダーを見る</Link>
      </div>
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
