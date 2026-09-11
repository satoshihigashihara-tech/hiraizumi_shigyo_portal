import Link from "next/link";
import { logout } from "@/app/actions/auth";
import SubmitButton from "@/app/components/SubmitButton";
import styles from "./layout.module.css";

/*
 * 一般利用者画面（/user 配下）の共通レイアウト。Server Component
 * （docs/routes.md 2章5項・13章「app/user/layout.js：一般利用者セッションの確認と
 *  利用者ナビゲーション」）。
 *
 * 未接続：セッションと役割の確認はまだ入れていない。
 * ------------------------------------------------------------------
 * docs/routes.md 8.1 の多層防御の1段目はこのレイアウトが担う。接続時は
 * このコンポーネントの先頭で
 *
 *     const { user } = await requireActiveUser("/user");
 *
 * を呼ぶ（utils/auth/guards.js に実装済み。未ログインなら
 * /login?returnTo=/user へ、停止中のアカウントなら /forbidden へ送る）。
 * 今この段階で呼ばないのは、イシュー #18 の対象が画面と仮データ表示までで、
 * 本人データの取得はバックエンド担当（東原）が接続するため。加えて、
 * requireActiveUser は Supabase への接続を必要とするので、
 * NEXT_PUBLIC_SUPABASE_URL / ANON_KEY が無い環境では仮データの画面自体を
 * 開けなくなり、イシュー #18 の完了条件（仮データでホームが表示される）を
 * 確認できなくなる。
 *
 * ログアウトは既存の logout（app/actions/auth.js）へ直接つなぐ。
 * 押しても何も起きないボタンを置かないため、案内ではなく実装済みのActionを使う。
 * なお現在の logout の遷移先は /login で、設計上の遷移先 `/` とは異なる
 * （docs/tasks.md 4.1 に既知の差分として記録済み）。Action側の修正は
 * バックエンド担当の範囲なので、この画面からは変更しない。
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
  { href: "/user/applications/new", label: "新規申請" },
  { href: "/user/profile", label: "プロフィール" },
];

export const metadata = {
  title: "利用者メニュー｜ひらいずみ志業ポータル",
};

export default function UserLayout({ children }) {
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
