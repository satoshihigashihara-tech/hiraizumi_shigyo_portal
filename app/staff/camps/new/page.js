import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import NewCampForm from "../NewCampForm";

export const metadata = { title: "キャンプを作る｜ひらいずみ志業ポータル" };

export default function NewStaffCampPage() {
  return <PageShell title="新しいキャンプを作る" description="利用期間と申請期限、参加対象者を入力してください。キャンプと対象者名簿をまとめて保存します。">
    <NewCampForm />
    <div><LinkButton href="/staff/camps">キャンプ管理へ戻る</LinkButton></div>
  </PageShell>;
}
