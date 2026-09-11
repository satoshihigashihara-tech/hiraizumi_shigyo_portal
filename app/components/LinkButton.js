import Link from "next/link";
import styles from "./Button.module.css";

/*
 * 内部リンク判定の基準となる、実在しないオリジン。
 * .invalid は RFC 2606 の予約TLDで、名前解決されることがない。
 * href を URL へ解決したとき origin がこのままなら「同じサイト内のパス」。
 */
const INTERNAL_ORIGIN = "https://internal.invalid";

/* 新しいタブを開かずに <a> で扱う（アプリを起動するだけの）スキーム */
const APP_SCHEMES = ["mailto:", "tel:"];

/**
 * href を "internal"（next/link）／"external"（別サイト）／"scheme"（mailto: / tel:）
 * へ分類する。
 *
 * 前方一致（/^https?:\/\//）だと、プロトコル相対の "//example.com" が内部扱いになり
 * next/link へ落ちて rel="noopener noreferrer" が付かない。URL として解決してから
 * origin を比べれば、相対パス・プロトコル相対・絶対URLを同じ規則で判定できる。
 *
 * @param {string|null|undefined} href
 * @returns {"internal"|"external"|"scheme"}
 */
function classifyHref(href) {
  if (typeof href !== "string" || href === "") return "internal";
  let url;
  try {
    url = new URL(href, INTERNAL_ORIGIN);
  } catch {
    // URLとして解釈できない値は next/link に委ね、ここで握りつぶさない
    return "internal";
  }
  if (APP_SCHEMES.includes(url.protocol)) return "scheme";
  if (url.protocol !== "http:" && url.protocol !== "https:") return "internal";
  return url.origin === INTERNAL_ORIGIN ? "internal" : "external";
}

/**
 * ボタンの見た目のリンク。Server Component。
 *
 * 画面内の遷移は next/link を使う。別サイトのURLのときだけ通常の <a> にし、
 * target="_blank" と rel="noopener noreferrer" を付ける
 * （.claude/rules/security.md）。mailto: / tel: などは新しいタブを開く意味がないので
 * target は付けず、rel だけ付けた <a> にする。
 *
 * 「押しても何も起きないボタン」を作らないため、href は必須とする。
 * 対象外機能の案内には ComingSoon を使う。
 *
 * @param {object} props
 * @param {string} props.href 遷移先。URLは docs/routes.md を正とする
 * @param {React.ReactNode} props.children ラベル
 * @param {"primary"|"secondary"|"danger"} [props.variant="secondary"]
 * @param {boolean} [props.fullWidthOnMobile=false] 480px以下で全幅にする
 */
export default function LinkButton({
  href,
  children,
  variant = "secondary",
  fullWidthOnMobile = false,
}) {
  const variantClass = styles[variant] ?? styles.secondary;
  const widthClass = fullWidthOnMobile ? styles.fullWidthOnMobile : "";
  const className = `${styles.button} ${variantClass} ${widthClass}`;
  const kind = classifyHref(href);

  if (kind !== "internal") {
    return (
      <a
        className={className}
        href={href}
        target={kind === "external" ? "_blank" : undefined}
        rel="noopener noreferrer"
      >
        {children}
      </a>
    );
  }

  return (
    <Link className={className} href={href}>
      {children}
    </Link>
  );
}
