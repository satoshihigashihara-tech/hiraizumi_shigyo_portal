import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { errorMessage } from "@/app/components/messages";
import { getCommunityGroup } from "@/utils/community-groups/queries";
import GroupForm from "./GroupForm";

export const metadata = { title: "団体申請を編集｜ひらいずみ志業ポータル" };

export default async function EditGroupPage({ params }) {
  const { groupId } = await params;
  const result = await getCommunityGroup(groupId, "edit");
  if (result.error === "not-found") notFound();
  if (result.error || !result.group) return <PageShell title="団体申請を編集"><AlertMessage tone="error" title="団体申請を開けませんでした"><p>{errorMessage(result.error)}</p></AlertMessage><LinkButton href="/user/groups" fullWidthOnMobile>団体一覧へ戻る</LinkButton></PageShell>;
  return <PageShell title="団体申請を編集" description="入力内容を保存するか、確認画面へ進んでください。"><GroupForm groupId={groupId} updatedAt={result.group.updated_at} initialFields={result.group.fields} /><LinkButton href={`/user/groups/${groupId}`} fullWidthOnMobile>団体詳細へ戻る</LinkButton></PageShell>;
}
