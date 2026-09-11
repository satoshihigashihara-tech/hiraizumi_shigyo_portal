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
 * スパルタキャンプの申請入口（/user/applications/new/camp）は認証必須のため、
 * 直接リンクせず /login?returnTo=... を経由する。returnTo の値は
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
const CAMP_APPLICATION_PATH = "/user/applications/new/camp";
const CAMP_LOGIN_HREF = `/login?returnTo=${encodeURIComponent(
  CAMP_APPLICATION_PATH,
)}`;

export const metadata = {
  title: "ひらいずみ志業ポータル",
  description:
    "平泉町志業シェアハウスの使用許可申請を受け付けるサイトです。対象者・利用条件・使用料・必要書類を確認し、申請へ進めます。",
};

export default function Home() {
  return (
    <div className={styles.page}>
      <PageShell
        title="平泉町志業シェアハウス"
        description="使用許可申請の受付窓口です。対象者・使用料・必要書類を確認してから申請へお進みください。"
      >
        <section>
          <h2>このサイトでできること</h2>
          <p>
            平泉町志業シェアハウスの使用許可申請ができます。申請いただいた内容は町が確認し、許可の可否をこの画面からお知らせします。申請しただけでは宿泊は確定しません。
          </p>
        </section>

        <section>
          <h2>対象者と利用条件</h2>
          <ul>
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

        <section>
          <h2>使用料</h2>
          {/*
           * docs/requirements.md 16章（506〜520行）。
           * 月9,000円の上限は「利用者の月間合計」ではなく「申請ごと」に
           * 適用されるため、合計額と誤解されない書き方にする。
           */}
          <AlertMessage tone="info" title="1人につき1日300円">
            <ul>
              <li>開始日と終了日の両方を日数に含めます。1泊2日は600円です。</li>
              <li>
                1つの申請で同じ月に9,000円を超える場合は、その月の分を9,000円までとします。上限は申請ごとに適用し、別々の申請の金額は合算しません。
              </li>
            </ul>
          </AlertMessage>
        </section>

        <section>
          <h2>必要書類</h2>
          {/* docs/requirements.md 8.2節（223〜225行） */}
          <AlertMessage tone="warning" title="保護者同意書が必要な方がいます">
            <p>
              未成年の方および18歳の高校生の方は、申請ごとに保護者同意書の提出が必要です。
            </p>
          </AlertMessage>
        </section>

        <section>
          <h2>申請へ進む</h2>
          <h3>スパルタキャンプ利用の申請</h3>
          <p>
            ログイン後に、申請できるキャンプを選んで手続きを進めます。
          </p>
          <div className={styles.actions}>
            <LinkButton
              href={CAMP_LOGIN_HREF}
              variant="primary"
              fullWidthOnMobile
            >
              スパルタキャンプ利用の申請へ進む
            </LinkButton>
          </div>

          <h3>地域活動での利用</h3>
          <ComingSoon
            title="地域活動での利用申請"
            description="準備中です。後日この画面から申請できるようになります。"
          />
        </section>

        <section>
          <h2>アカウントをお持ちの方</h2>
          <p>
            申請の状況確認や続きの手続きは、ログイン後の画面から行えます。
          </p>
          <div className={styles.actions}>
            <LinkButton href="/login" variant="secondary" fullWidthOnMobile>
              ログインはこちら
            </LinkButton>
          </div>
        </section>

        <section>
          <h2>利用状況カレンダー</h2>
          <ComingSoon title="利用状況カレンダー" description="準備中です。" />
        </section>
      </PageShell>
    </div>
  );
}
