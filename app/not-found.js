import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import styles from "./Boundary.module.css";

export const metadata = {
  title: "ページが見つかりません｜ひらいずみ志業ポータル",
};

export default function NotFound() {
  return (
    <PageShell
      title="ページが見つかりません"
      description="URLが間違っているか、表示できないページです。"
    >
      <div className={styles.panel}>
        <p>申請の情報が見つからない場合は、申請一覧からもう一度お探しください。</p>
        <div className={styles.actions}>
          <LinkButton href="/user/applications" variant="primary" fullWidthOnMobile>
            申請一覧を開く
          </LinkButton>
          <LinkButton href="/" fullWidthOnMobile>トップへ戻る</LinkButton>
        </div>
      </div>
    </PageShell>
  );
}
