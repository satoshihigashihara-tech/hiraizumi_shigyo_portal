import AlertMessage from "@/app/components/AlertMessage";
import ComingSoon from "@/app/components/ComingSoon";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import styles from "./page.module.css";

/*
 * トップ画面（/）。Server Component（docs/routes.md 5章・141行の一覧）。
 *
 * 未ログインで開かれる前提の公開画面なので、個人・団体を特定できる情報は
 * 一切置かず、データ取得もしない（全て静的な公開情報）。
 *
 * 用語は「使用許可申請」で統一する。「予約」と書くと、申請した時点で
 * 宿泊が確定するように読めるが、docs/requirements.md 4.3 のとおり
 * 「申請と同時に宿泊を確定する機能」は対象外のため。
 *
 * スパルタキャンプの申請入口は認証必須のため、直接リンクせず
 * /login?returnTo=... を経由する。申請フォーム自体（新規作成画面）は未実装
 * のため、戻り先は現時点で存在する申請一覧（/user/applications）にする。
 * ここを申請フォームのパスにすると、ログイン成功後に 404 へ遷移する。
 * returnTo の値は
 * utils/auth/return-to.js の safeReturnTo() が通す「/ で始まる内部パス」の形で
 * ハードコードする。
 *
 * 地域活動の申請入口と公開カレンダー（/calendar）は未実装のため、
 * 押せるように見えるボタンを置かず ComingSoon で案内する
 * （docs/frontend-handoff.md・app/components/ComingSoon.js）。
 */

/*
 * ログイン画面へ渡す戻り先。"/" 部分をエンコードした値を定数にしておき、
 * 文字列の中に直接 %2F を書いて読みにくくならないようにする。
 */
const CAMP_APPLICATION_PATH = "/user/applications";
const CAMP_LOGIN_HREF = `/login?returnTo=${encodeURIComponent(
  CAMP_APPLICATION_PATH,
)}`;

/*
 * 画面の説明文。metadata.description と本文（PageShell）で同じ内容を
 * 二度書くと片方だけ更新され食い違うため、定数にして共有する。
 */
const PAGE_DESCRIPTION =
  "使用許可申請の受付窓口です。対象者・使用料・必要書類を確認してから申請へお進みください。";

/*
 * title は app/layout.js のルート metadata と同一になるため上書きしない
 * （二重定義すると片方だけ更新され取り残されるため）。
 */
export const metadata = {
  description: PAGE_DESCRIPTION,
};

export default function Home() {
  return (
    <div className={styles.page}>
      <PageShell
        title="平泉町志業シェアハウス"
        description={PAGE_DESCRIPTION}
      >
        <section className={styles.section}>
          <h2 className={styles.sectionTitle}>このサイトでできること</h2>
          <p>
            平泉町志業シェアハウスの使用許可申請ができます。申請いただいた内容は町が確認し、許可の可否をこの画面からお知らせします。申請しただけでは宿泊は確定しません。
          </p>
        </section>

        <section className={styles.section}>
          <h2 className={styles.sectionTitle}>対象者と利用条件</h2>
          <ul className={styles.list}>
            <li>
              スパルタキャンプの参加者として、対象期間の利用を申請する方
            </li>
            <li>
              スパルタキャンプ修了後に、町内での起業準備や地域振興につながる活動を行う方
            </li>
            <li>町が認める地域活動を行う個人または団体の方</li>
            <li>
              大学のゼミ・研究室、自治体や企業の視察研修、地域イベントの参加・運営団体の方
            </li>
          </ul>
          <p>
            宿泊を伴わない共用部分だけの利用、および観光目的の宿泊は対象外です。
          </p>
        </section>

        <section className={styles.section}>
          <h2 className={styles.sectionTitle}>使用料</h2>
          {/*
           * docs/requirements.md 16章（506〜520行）。
           * 月9,000円の上限は「利用者の月間合計」ではなく「申請ごと」に
           * 適用されるため、合計額と誤解されない書き方にする。
           */}
          <div className={styles.feeBox}>
            <p className={styles.feeTitle}>1人につき1日300円</p>
            <ul className={styles.list}>
              <li>開始日と終了日の両方を日数に含めます。1泊2日は600円です。</li>
              <li>
                1つの申請で同じ月に9,000円を超える場合は、その月の分を9,000円までとします。上限は申請ごとに適用し、別々の申請の金額は合算しません。
              </li>
            </ul>
          </div>
        </section>

        <section className={styles.section}>
          <h2 className={styles.sectionTitle}>必要書類</h2>
          {/* docs/requirements.md 8.2節（223〜225行） */}
          <AlertMessage tone="warning" title="保護者同意書が必要な方がいます">
            <p>
              未成年の方および18歳の高校生の方は、申請ごとに保護者同意書の提出が必要です。
            </p>
          </AlertMessage>
        </section>

        <section className={styles.section}>
          <h2 className={styles.sectionTitle}>申請へ進む</h2>
          <h3 className={styles.subsectionTitle}>スパルタキャンプ利用の申請</h3>
          <p>
            ログイン後の申請一覧から、手続きの状況確認と続きの操作ができます。
          </p>
          <div className={styles.actions}>
            <LinkButton
              href={CAMP_LOGIN_HREF}
              variant="primary"
              fullWidthOnMobile
            >
              ログインして申請一覧へ進む
            </LinkButton>
          </div>

          <h3 className={styles.subsectionTitle}>地域活動での利用</h3>
          <ComingSoon
            title="地域活動での利用申請"
            description="準備中です。後日この画面から申請できるようになります。"
          />
        </section>

        <section className={styles.section}>
          <h2 className={styles.sectionTitle}>アカウントをお持ちの方</h2>
          <p>
            申請の状況確認や続きの手続きは、ログイン後の画面から行えます。
          </p>
          <div className={styles.actions}>
            <LinkButton href="/login" variant="secondary" fullWidthOnMobile>
              ログイン画面を開く
            </LinkButton>
          </div>
        </section>

        <section className={styles.section}>
          <h2 className={styles.sectionTitle}>利用状況カレンダー</h2>
          <ComingSoon description="空き状況の確認は後日この画面でご覧いただけるようになります。" />
        </section>
      </PageShell>
    </div>
  );
}
