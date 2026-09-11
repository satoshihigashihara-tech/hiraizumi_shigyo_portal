import styles from "./EmptyState.module.css";

/**
 * 空一覧の案内表示。Server Component。
 *
 * docs/coding_rules.md 7章が求める「空状態」を共通化する。
 * action を渡さなければリンクやボタンを一切描画しない。
 *
 * @param {object} props
 * @param {string} [props.title="表示できる情報はありません"]
 * @param {string} [props.description] 次にできることの説明
 * @param {React.ReactNode} [props.action] LinkButton などの導線
 */
export default function EmptyState({
  title = "表示できる情報はありません",
  description,
  action,
}) {
  return (
    <div className={styles.empty}>
      <p className={styles.title}>{title}</p>
      {description && <p className={styles.description}>{description}</p>}
      {action}
    </div>
  );
}
