"use client";

import Link from "next/link";
import { withMode } from "@/utils/navigation/mode";
import { SiteAccount, useSiteAudience } from "./SiteHeader";
import styles from "./SiteChrome.module.css";

export default function SiteFooter() {
  const { mode, area } = useSiteAudience();
  const links = area === "staff"
    ? [["/staff", "職員ホーム"], ["/staff/camps", "キャンプ管理"], ["/staff/community/groups", "団体申請の審査"], ["/staff/calendar", "職員カレンダー"]]
    : area === "user"
      ? [["/user", "利用者ホーム"], ["/user/applications", "申請一覧"], ["/user/groups", "団体申請"], ["/user/profile", "プロフィール"]]
      : [["/", "利用区分を選ぶ"], ["/camp", "キャンプ利用"], ["/calendar", "利用状況カレンダー"]];
  return <footer className={styles.footer}>
    <div className={styles.footerInner}>
      <nav aria-label="サイトマップ"><h2>サイトマップ</h2><ul>
        {links.map(([href, label]) => <li key={href}><Link href={withMode(href, area === "user" ? mode : null)}>{label}</Link></li>)}
      </ul></nav>
      <div className={styles.footerAccount}><SiteAccount area={area} /></div>
      <p className={styles.copyright}>© 2026 ひらいずみ志業ポータル開発チーム</p>
    </div>
  </footer>;
}
