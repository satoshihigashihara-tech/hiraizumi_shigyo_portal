"use client";

import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import buttonStyles from "@/app/components/Button.module.css";
import styles from "./Boundary.module.css";

export default function Error({ retry }) {
  return (
    <PageShell
      title="画面を表示できませんでした"
      description="一時的な問題が発生しました。入力途中の内容がある場合は、再試行前に控えてください。"
    >
      <div className={styles.panel} role="alert">
        <p>時間をおいて再度お試しください。繰り返し発生する場合は、町の担当へご連絡ください。</p>
        <div className={styles.actions}>
          <button
            className={`${buttonStyles.button} ${buttonStyles.primary} ${buttonStyles.fullWidthOnMobile}`}
            type="button"
            onClick={() => retry()}
          >
            もう一度試す
          </button>
          <LinkButton href="/" fullWidthOnMobile>トップへ戻る</LinkButton>
        </div>
      </div>
    </PageShell>
  );
}
