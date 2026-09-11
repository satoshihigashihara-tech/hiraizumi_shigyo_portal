import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { errorMessage } from "@/app/components/messages";
import { getUserProfile } from "@/utils/profile/queries";
import ProfileForm from "./ProfileForm";
import styles from "./page.module.css";

export const metadata = {
  title: "プロフィール｜ひらいずみ志業ポータル",
  description: "本人情報と緊急連絡先を確認・変更できます。",
};

function first(value) {
  return Array.isArray(value) ? value[0] : value;
}

export default async function UserProfilePage({ searchParams }) {
  const query = (await searchParams) ?? {};
  const result = await getUserProfile();
  const saved = first(query.saved) === "1";

  return (
    <PageShell title="プロフィール" description="申請で使用する本人情報と緊急連絡先を登録できます。">
      {saved && (
        <AlertMessage tone="success" title="プロフィールを保存しました">
          <p>次回の申請でも、この情報を確認して使用できます。</p>
        </AlertMessage>
      )}
      {result.error ? (
        <AlertMessage tone="error" title="プロフィールを読み込めませんでした">
          <p>{errorMessage(result.error)}</p>
        </AlertMessage>
      ) : (
        <ProfileForm profile={result.profile} />
      )}
      <div className={styles.actions}>
        <LinkButton href="/user" fullWidthOnMobile>利用者ホームへ戻る</LinkButton>
      </div>
    </PageShell>
  );
}
