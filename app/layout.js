import Link from "next/link";
import { Suspense } from "react";
import SiteHeader, { SiteAudienceProvider } from "@/app/components/SiteHeader";
import SiteFooter from "@/app/components/SiteFooter";
import chromeStyles from "@/app/components/SiteChrome.module.css";
import "./globals.css";

export const metadata = {
  title: "ひらいずみ志業ポータル",
  description: "平泉町志業シェアハウスの使用許可申請システム",
};

function HeaderFallback() {
  return <>
    <a className={chromeStyles.skipLink} href="#main-content">本文へ移動する</a>
    <header className={chromeStyles.header}><div className={chromeStyles.headerInner}>
      <Link className={chromeStyles.brand} href="/">ひらいずみ志業ポータル</Link>
      <p className={chromeStyles.audience} aria-hidden="true" />
      <div className={chromeStyles.account}><Link href="/login">ログイン</Link></div>
      <nav className={chromeStyles.nav} aria-label="共通メニュー"><ul>
        <li><Link href="/">サービス紹介</Link></li>
        <li><Link href="/welcome-user">申請を始める</Link></li>
        <li><Link href="/calendar">利用状況カレンダー</Link></li>
      </ul></nav>
    </div></header>
  </>;
}

function FooterFallback() {
  return <footer className={chromeStyles.footer}><div className={chromeStyles.footerInner}>
    <nav aria-label="フッターメニュー"><ul>
      <li><Link href="/">サービス紹介</Link></li>
      <li><Link href="/welcome-user">申請を始める</Link></li>
      <li><Link href="/camp">キャンプ利用</Link></li>
      <li><Link href="/calendar">利用状況カレンダー</Link></li>
    </ul></nav>
    <div className={chromeStyles.footerAccount}><Link href="/login">ログイン</Link></div>
    <p className={chromeStyles.copyright}>© 2026 ひらいずみ志業ポータル開発チーム</p>
  </div></footer>;
}

export default function RootLayout({ children }) {
  return (
    <html lang="ja">
      <body><SiteAudienceProvider>
        <Suspense fallback={<HeaderFallback />}><SiteHeader /></Suspense>
        <main id="main-content">{children}</main>
        <Suspense fallback={<FooterFallback />}><SiteFooter /></Suspense>
      </SiteAudienceProvider></body>
    </html>
  );
}
