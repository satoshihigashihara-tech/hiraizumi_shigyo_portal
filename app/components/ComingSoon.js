import styles from "./ComingSoon.module.css";

/*
 * 「準備中」表示。Server Component。
 *
 * docs/frontend-handoff.md「今回の段階で対象外の機能は、動くように見せる
 * ボタンを置かず、必要なら準備中と表示します」。
 *
 * そのためこの部品は <button> と <a> を一切描画しない。無効化したボタンを
 * 置くと「押せば動くはず」と誤解されるため、構造で禁止する。
 * 「準備中」の文字は aria-hidden にせず、支援技術にも伝える。
 */

/**
 * @param {object} props
 * @param {string} [props.title="準備中"] 対象機能の名前
 * @param {string} [props.description] いつ・どこで使えるようになるかの補足
 */
export default function ComingSoon({ title = "準備中", description }) {
  return (
    <div className={styles.comingSoon}>
      <p className={styles.title}>
        <span className={styles.badge}>準備中</span>
        <span>{title}</span>
      </p>
      {description && <p className={styles.description}>{description}</p>}
    </div>
  );
}
