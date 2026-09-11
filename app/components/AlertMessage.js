import { errorMessage, fieldLabel } from "./messages";
import styles from "./AlertMessage.module.css";

const TONE_PREFIXES = {
  error: "エラー",
  warning: "注意",
  success: "完了",
  info: "お知らせ",
};

/**
 * 画面上部のエラー・お知らせ表示。Server Component。
 *
 * バックエンドの `{ error, fields, fieldErrors }`（docs/routes.md 9.5）を
 * 「上部サマリー＋項目別エラー」へそのまま流し込めるようにする。
 * トーンごとの接頭辞テキストを必ず描画し、色のみで種別を伝えない
 * （docs/coding_rules.md 7章）。
 *
 * @param {object} props
 * @param {"error"|"warning"|"success"|"info"} [props.tone="info"]
 * @param {string} [props.title] 見出し。省略時は接頭辞だけを表示する
 * @param {React.ReactNode} [props.children] 本文
 * @param {{href: string, label: string}[]} [props.items]
 *        エラー箇所へのアンカーリンク。docs/requirements.md 8.3
 *        「エラー箇所へ移動できるようにする」を満たす
 */
export default function AlertMessage({
  tone = "info",
  title,
  children,
  items,
}) {
  const prefix = TONE_PREFIXES[tone] ?? TONE_PREFIXES.info;
  const isError = tone === "error";
  const toneClass = styles[tone] ?? styles.info;

  return (
    <div
      className={`${styles.alert} ${toneClass}`}
      role={isError ? "alert" : "status"}
      aria-live={isError ? "assertive" : "polite"}
    >
      <p className={styles.heading}>
        <span className={styles.prefix}>{prefix}</span>
        {title && <span>{title}</span>}
      </p>

      {children && <div className={styles.body}>{children}</div>}

      {Array.isArray(items) && items.length > 0 && (
        <ul className={styles.items}>
          {items.map((item) => (
            <li key={item.href}>
              <a href={item.href}>{item.label}</a>
            </li>
          ))}
        </ul>
      )}
    </div>
  );
}

/**
 * バックエンドの fieldErrors（フォーム名 → エラーコード）を
 * AlertMessage の items 形式へ変換する。
 *
 * エラーコードは errorMessage() で日本語化し、コード文字列を画面へ出さない。
 * href は該当入力欄の id を指す前提なので、FormField の id には
 * フォームの name と同じ値を渡す。
 *
 * @param {Record<string, string>|null|undefined} fieldErrors
 * @returns {{href: string, label: string}[]}
 */
export function errorAlertItems(fieldErrors) {
  if (!fieldErrors || typeof fieldErrors !== "object") return [];
  return Object.entries(fieldErrors).map(([name, code]) => ({
    href: `#${name}`,
    label: `${fieldLabel(name)}：${errorMessage(code)}`,
  }));
}
