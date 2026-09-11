import Link from "next/link";
import { logout } from "@/app/actions/auth";
import SubmitButton from "@/app/components/SubmitButton";
import { requireActiveUser } from "@/utils/auth/guards";
import styles from "./layout.module.css";

/*
 * 一般利用者画面（/user 配下）の共通レイアウト。Server Component
 * （docs/routes.md 2章5項・13章「app/user/layout.js：一般利用者セッションの確認と
 *  利用者ナビゲーション」）。
 *
 * セッションとactive状態は requireActiveUser で確認する。未ログインなら
 * /login?returnTo=/user、停止中または情報整理中なら
 * /forbidden?reason=account-unavailable へ送る。各Server Actionとデータ取得も
 * それぞれ認可するため、このlayoutだけを防御にはしない。
 *
 * ログアウトは既存の logout（app/actions/auth.js）へ直接つなぎ、公開トップへ戻る。
 *
 * 現在地の強調（aria-current="page"）は入れていない。判定には usePathname が
 * 必要で、共通ヘッダー全体を Client Component にすることになるため
 * （docs/routes.md 9.1「ブラウザ操作が必要な部分だけを小さなClient Componentにする」）。
 * 必要になった時点で、リンク部分だけを切り出して追加する。
 */

/*
 * ヘッダーのナビゲーション。
 *
 * 遷移先は docs/routes.md 6.1・6.2 のURLに合わせる。各画面はイシュー #19 以降で
 * 作成するため、現時点ではリンク先が未作成（404）のものがある。
 * イシュー #18 の対象は「導線があること」なので、押せるリンクとして置く。
 *
 * 団体（/user/groups）と招待はこの段階の対象外のため、ここには置かない
 * （ホーム側で ComingSoon として案内する）。
 */
const NAV_ITEMS = [
  { href: "/user", label: "ホーム" },
  { href: "/user/applications", label: "申請一覧" },
];

export const metadata = {
  title: "利用者メニュー｜ひらいずみ志業ポータル",
};

export default async function UserLayout({ children }) {
  await requireActiveUser("/user");

  return (
    <div className={styles.layout}>
      {/*
       * キーボード操作でヘッダーのリンクを読み飛ばせるようにする。
       * 普段は見えず、Tabでフォーカスが当たったときだけ表示される
       * （docs/coding_rules.md 7章）。
       */}
      <a className={styles.skipLink} href="#user-main">
        本文へ移動する
      </a>

      <header className={styles.header}>
        <div className={styles.headerInner}>
          <div className={styles.brandRow}>
            <Link className={styles.brand} href="/user">
              ひらいずみ志業ポータル
            </Link>

            {/*
             * useFormStatus は同じ <form> の子孫でのみ pending を返すため、
             * SubmitButton は必ず form の内側へ置く（app/components/README.md）。
             */}
            <form className={styles.logoutForm} action={logout}>
              <SubmitButton variant="secondary" pendingLabel="ログアウト中…">
                ログアウト
              </SubmitButton>
            </form>
          </div>

          <nav className={styles.nav} aria-label="利用者メニュー">
            <ul className={styles.navList}>
              {NAV_ITEMS.map((item) => (
                <li key={item.href}>
                  <Link className={styles.navLink} href={item.href}>
                    {item.label}
                  </Link>
                </li>
              ))}
            </ul>
          </nav>
        </div>
      </header>

      {/* id はページ先頭のスキップリンクの移動先。tabIndex は付けない（見出しへ送る） */}
      <main className={styles.main} id="user-main">
        {children}
      </main>
    </div>
  );
}
