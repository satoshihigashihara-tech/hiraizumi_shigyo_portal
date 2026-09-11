import Link from "next/link";
import { logout } from "@/app/actions/auth";
import SubmitButton from "@/app/components/SubmitButton";
import { requireStaff } from "@/utils/auth/guards";
import styles from "./layout.module.css";

const NAV_ITEMS = [
  { href: "/staff", label: "ホーム" },
  { href: "/staff/camps", label: "キャンプ管理" },
];

export const metadata = {
  title: "職員メニュー｜ひらいずみ志業ポータル",
};

export default async function StaffLayout({ children }) {
  await requireStaff("/staff");

  return (
    <div className={styles.layout}>
      <a className={styles.skipLink} href="#staff-main">
        本文へ移動する
      </a>
      <header className={styles.header}>
        <div className={styles.headerInner}>
          <div className={styles.brandRow}>
            <Link className={styles.brand} href="/staff">
              ひらいずみ志業ポータル 職員用
            </Link>
            <form className={styles.logoutForm} action={logout}>
              <SubmitButton variant="secondary" pendingLabel="ログアウト中…">
                ログアウト
              </SubmitButton>
            </form>
          </div>
          <nav className={styles.nav} aria-label="職員メニュー">
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
      <main className={styles.main} id="staff-main">
        {children}
      </main>
    </div>
  );
}
