import styles from "./PageShell.module.css";

/**
 * 利用者画面の外枠。各画面はこれで包むだけで、余白・最大幅・文字サイズ・
 * ダークモード対応・375px対策とCSS基準値（デザイントークン）を受け取る。
 *
 * Server Component（docs/routes.md 9.1）。"use client" を付けない。
 * 共通部品は var(--sg-*) を参照するため、原則としてこの内側で使う。
 *
 * @param {object} props
 * @param {string} [props.title] 画面見出し。渡すと h1 を描画する
 * @param {string} [props.description] 見出しの下の補足文
 * @param {React.ReactNode} props.children 本文（縦並び・24px間隔）
 */
export default function PageShell({ title, description, children }) {
  return (
    <div className={styles.shell}>
      {(title || description) && (
        <div className={styles.header}>
          {title && <h1 className={styles.title}>{title}</h1>}
          {description && <p className={styles.description}>{description}</p>}
        </div>
      )}
      <div className={styles.body}>{children}</div>
    </div>
  );
}
