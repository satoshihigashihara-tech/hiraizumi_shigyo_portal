import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { errorMessage } from "@/app/components/messages";
import { getCommunityGroup } from "@/utils/community-groups/queries";
import GroupReview from "../../GroupReview";
import SubmitGroup from "./SubmitGroup";

export const metadata = { title: "団体申請を確認｜ひらいずみ志業ポータル" };

export default async function ConfirmGroupPage({ params }) {
  const { groupId } = await params;
  const result = await getCommunityGroup(groupId, "confirm");
  if (result.error === "not-found") notFound();
  if (result.error || !result.group) return <PageShell title="団体申請を確認"><AlertMessage tone="error" title="団体申請を確認できませんでした"><p>{errorMessage(result.error)}</p></AlertMessage><LinkButton href={result.group ? `/user/groups/${groupId}/edit` : "/user/groups"} fullWidthOnMobile>戻る</LinkButton></PageShell>;
  return <PageShell title="団体申請を確認" description="入力内容に間違いがないか確認してください。"><GroupReview group={result.group} /><SubmitGroup group={result.group} /></PageShell>;
}
