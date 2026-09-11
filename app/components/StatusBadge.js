import { STATUS_KIND_LABELS, statusLabel, statusTone } from "./status-labels";
import styles from "./StatusBadge.module.css";

/**
 * 状態バッジ。Server Component。
 *
 * docs/coding_rules.md 7章：
 * - 色だけで状態を区別せず、必ず文字でも表示する
 *   → バッジ内に必ず日本語ラベルを描画し、色は補助（左ボーダー3px＋背景＋文字色）
 * - 申請・納付・滞在の状態を分ける
 *   → kind を必須にし、種別名を常にスクリーンリーダーへ伝える
 *
 * @param {object} props
 * @param {"application"|"group"|"payment"|"stay"} [props.kind="application"] 状態の種別
 * @param {string|null|undefined} props.value DBの保存値。未知・null でも壊れない
 * @param {boolean} [props.showKind=false] true なら種別名を視覚的にも表示する
 */
export default function StatusBadge({
  kind = "application",
  value,
  showKind = false,
}) {
  const tone = statusTone(kind, value);
  const label = statusLabel(kind, value);
  // Object.hasOwn で自前のキーに限定する。`??` だけでは "toString" のような
  // Object.prototype のプロパティ名を渡されたとき関数が左辺に入り、
  // フォールバックが働かない（status-labels.js・messages.js と同じ対策）。
  const kindLabel = Object.hasOwn(STATUS_KIND_LABELS, kind)
    ? STATUS_KIND_LABELS[kind]
    : "状態";

  return (
    <span className={`${styles.badge} ${styles[tone]}`}>
      {showKind ? (
        <span className={styles.kind}>{kindLabel}</span>
      ) : (
        <span className={styles.srOnly}>{kindLabel}：</span>
      )}
      <span>{label}</span>
    </span>
  );
}

/**
 * バッジの併記用コンテナ。申請・納付・滞在の3バッジを横並びにし、
 * 375pxでは折り返す。
 *
 * @param {object} props
 * @param {React.ReactNode} props.children StatusBadge を並べる
 */
export function StatusRow({ children }) {
  return <div className={styles.row}>{children}</div>;
}
