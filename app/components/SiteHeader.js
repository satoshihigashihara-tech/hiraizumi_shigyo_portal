"use client";

import Link from "next/link";
import { createContext, useContext, useEffect, useMemo, useState } from "react";
import { usePathname, useSearchParams } from "next/navigation";
import { logout } from "@/app/actions/auth";
import SubmitButton from "@/app/components/SubmitButton";
import { normalizeMode, withMode } from "@/utils/navigation/mode";
import styles from "./SiteChrome.module.css";

const AudienceContext = createContext({ audienceMode: null, setAudienceMode: () => {} });

export function SiteAudienceProvider({ children }) {
  const [audienceMode, setAudienceMode] = useState(null);
  const value = useMemo(() => ({ audienceMode, setAudienceMode }), [audienceMode]);
  return <AudienceContext.Provider value={value}>{children}</AudienceContext.Provider>;
}

export function AudienceSetter({ mode }) {
  const { setAudienceMode } = useContext(AudienceContext);
  useEffect(() => {
    setAudienceMode(normalizeMode(mode));
    return () => setAudienceMode(null);
  }, [mode, setAudienceMode]);
  return null;
}

export function useSiteAudience() {
  const pathname = usePathname();
  const searchParams = useSearchParams();
  const { audienceMode } = useContext(AudienceContext);
  let mode = audienceMode ?? normalizeMode(searchParams.get("mode"));
  if (!mode && pathname === "/camp") mode = "camp";
  if (!mode && (pathname.startsWith("/user/groups") || pathname.startsWith("/invite"))) mode = "fieldwork";
  if (!mode && ["/login", "/signup"].includes(pathname)) {
    const returnTo = searchParams.get("returnTo") ?? "";
    if (returnTo.includes("mode=camp") || returnTo.includes("/applications/new/camp")) mode = "camp";
    if (returnTo.includes("mode=fieldwork") || returnTo.includes("/user/groups") || returnTo.includes("/invite")) mode = "fieldwork";
  }
  const area = pathname.startsWith("/staff") ? "staff" : pathname.startsWith("/user") ? "user" : "public";
  return { pathname, mode, area };
}

function audienceLabel(area, mode) {
  if (area === "staff") return "職員の方へ";
  if (mode === "camp") return "スパルタキャンプ参加者の方へ";
  if (mode === "fieldwork") return "フィールドワークを行う方へ";
  if (area === "user") return "一般利用者の方へ";
  return "利用する方へ";
}

export function SiteAccount({ area }) {
  return area === "user" || area === "staff" ? (
    <form action={logout}>
      <SubmitButton variant="secondary" pendingLabel="ログアウト中…">ログアウト</SubmitButton>
    </form>
  ) : <Link href="/login">ログイン</Link>;
}

export default function SiteHeader() {
  const { pathname, mode, area } = useSiteAudience();
  const nav = area === "staff"
    ? [["/staff", "職員ホーム"], ["/staff/camps", "キャンプ管理"], ["/staff/community/groups", "団体審査"], ["/staff/calendar", "職員カレンダー"]]
    : area === "user"
      ? mode === "fieldwork"
        ? [["/user", "ホーム"], ["/user/applications", "参加者申請"], ["/user/profile", "プロフィール"]]
        : [["/user", "ホーム"], ["/user/profile", "プロフィール"]]
      : [["/", "利用区分"], ["/calendar", "利用状況カレンダー"]];

  return <>
    <a className={styles.skipLink} href="#main-content">本文へ移動する</a>
    <header className={styles.header}>
      <div className={styles.headerInner}>
        <Link className={styles.brand} href="/">ひらいずみ志業ポータル</Link>
        <p className={styles.audience}>{audienceLabel(area, mode)}</p>
        <div className={styles.account}><SiteAccount area={area} /></div>
        <nav className={styles.nav} aria-label="共通メニュー"><ul>
          {nav.map(([href, label]) => <li key={href}><Link aria-current={pathname === href ? "page" : undefined} href={withMode(href, area === "user" ? mode : null)}>{label}</Link></li>)}
        </ul></nav>
      </div>
    </header>
  </>;
}
