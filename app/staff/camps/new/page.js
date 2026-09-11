import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import NewCampForm from "../NewCampForm";

export const metadata = { title: "キャンプを作る｜ひらいずみ志業ポータル" };

export default function NewStaffCampPage() {
  return <PageShell title="新しいキャンプを作る" description="利用期間と申請期限を入力してください。">
    <NewCampForm />
    <div><LinkButton href="/staff/camps">キャンプ管理へ戻る</LinkButton></div>
  </PageShell>;
}
