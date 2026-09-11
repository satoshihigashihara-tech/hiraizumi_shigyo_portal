"use client";

/*
 * 共通部品のうち唯一の Client Component（docs/routes.md 9.2
 * 「送信中のボタン無効化と進行表示」だけをClientにする）。
 *
 * useFormStatus は react-dom から import する。Next.js 16 のガイド
 * node_modules/next/dist/docs/01-app/02-guides/forms.md「Pending states」に
 * 従う。返り値のうち pending だけを使う（React 19 では data / method / action
 * も返るが、ここでは不要）。
 *
 * 制約：useFormStatus は「同じ <form> の子孫として描画された別コンポーネント」
 * でのみ pending を返す。<form> と同じコンポーネント内で呼んでも常に false に
 * なるため、必ず <form action={...}> の内側へ <SubmitButton /> を置く。
 * useActionState の pending を使う画面は、pending propsで上書きできる。
 */

import { useFormStatus } from "react-dom";
import styles from "./Button.module.css";

/**
 * 送信ボタン。送信中は無効化し、文字でも送信中であることを伝える
 * （docs/requirements.md 8.3・docs/coding_rules.md 7章）。
 *
 * @param {object} props
 * @param {React.ReactNode} props.children 通常時のラベル
 * @param {string} [props.pendingLabel="送信中…"] 送信中のラベル
 * @param {"primary"|"secondary"|"danger"} [props.variant="primary"]
 * @param {boolean} [props.disabled=false] 送信中以外の理由で無効化する場合
 * @param {boolean} [props.pending] useActionState の pending で上書きする場合に渡す
 * @param {boolean} [props.fullWidthOnMobile=false] 480px以下で全幅にする
 */
export default function SubmitButton({
  children,
  pendingLabel = "送信中…",
  variant = "primary",
  disabled = false,
  pending: pendingProp,
  fullWidthOnMobile = false,
}) {
  const { pending } = useFormStatus();
  const isPending = pendingProp ?? pending;
  const variantClass = styles[variant] ?? styles.primary;
  const widthClass = fullWidthOnMobile ? styles.fullWidthOnMobile : "";

  return (
    <button
      type="submit"
      className={`${styles.button} ${variantClass} ${widthClass}`}
      disabled={isPending || disabled}
      aria-busy={isPending}
    >
      {isPending ? pendingLabel : children}
    </button>
  );
}
