import Link from "next/link";
import styles from "./Button.module.css";

/**
 * ボタンの見た目のリンク。Server Component。
 *
 * 画面内の遷移は next/link を使う。外部リンク（http(s):// 始まり）のときだけ
 * 通常の <a> にし、target="_blank" と rel="noopener noreferrer" を付ける
 * （.claude/rules/security.md）。
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
  const isExternal = /^https?:\/\//i.test(href ?? "");

  if (isExternal) {
    return (
      <a
        className={className}
        href={href}
        target="_blank"
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
