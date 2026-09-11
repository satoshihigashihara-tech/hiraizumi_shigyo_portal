import Link from "next/link";
import styles from "./Button.module.css";

/*
 * 内部リンク判定の基準となる、実在しないオリジン。
 * .invalid は RFC 2606 の予約TLDで、名前解決されることがない。
 * href を URL へ解決したとき origin がこのままなら「同じサイト内のパス」。
 */
const INTERNAL_ORIGIN = "https://internal.invalid";

/* 画面遷移として許可するスキーム。ここに無いものは描画しない */
const PAGE_SCHEMES = ["http:", "https:"];

/* 新しいタブを開かずに <a> で扱う（アプリを起動するだけの）スキーム */
const APP_SCHEMES = ["mailto:", "tel:"];

/**
 * href を "internal"（next/link）／"external"（別サイト）／"scheme"（mailto: / tel:）
 * ／"blocked"（描画しない）へ分類する。
 *
 * 判定の根拠：
 * 1. 前方一致（/^https?:\/\//）だと、プロトコル相対の "//example.com" が内部扱いになり
 *    next/link へ落ちて rel="noopener noreferrer" が付かない。URL として解決してから
 *    origin を比べれば、相対パス・プロトコル相対・絶対URLを同じ規則で判定できる。
 * 2. 許可列挙にする。「javascript: / data: / vbscript: を除く」という除外列挙は、
 *    新しい危険なスキームが増えるたびに書き足す前提になり、書き漏らすと
 *    <a href="javascript:..."> がそのまま描画される。逆に「同一オリジンの相対パスと
 *    http: / https: / mailto: / tel: だけを通す」と決めておけば、想定外の値は
 *    常に安全側（blocked）へ落ちる（.claude/rules/security.md）。
 *    この部品は #17〜#24 の8画面が使う土台なので、1か所の緩さが全画面へ広がる。
 * 3. href が無い・URLとして解釈できない値も blocked。押しても遷移しないボタンを
 *    描画するより、出さないほうが不具合に気づける（href は必須props）。
 *
 * @param {string|null|undefined} href
 * @returns {"internal"|"external"|"scheme"|"blocked"}
 */
function classifyHref(href) {
  if (typeof href !== "string" || href === "") return "blocked";
  let url;
  try {
    url = new URL(href, INTERNAL_ORIGIN);
  } catch {
    return "blocked";
  }
  if (APP_SCHEMES.includes(url.protocol)) return "scheme";
  if (!PAGE_SCHEMES.includes(url.protocol)) return "blocked";
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
 * 許可していないスキーム（javascript: など）や解釈できない href は何も描画しない。
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

  // 許可していないスキームは <a> にも next/link にも渡さない
  if (kind === "blocked") return null;

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
