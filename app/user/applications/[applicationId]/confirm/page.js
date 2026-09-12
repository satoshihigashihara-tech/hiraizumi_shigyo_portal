import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { errorMessage } from "@/app/components/messages";
import CampApplicationReview from "../CampApplicationReview";
import CommunityApplicationReview from "../CommunityApplicationReview";
import GroupParticipantReview from "../GroupParticipantReview";
import { getCampApplicationForConfirm } from "@/utils/camp-applications/queries";
import { getCommunityApplication } from "@/utils/community-applications/queries";
import { getGroupParticipantApplication } from "@/utils/group-participants/queries";
import { getUserApplicationUsageType } from "@/utils/user-applications/queries";
import SubmitConfirmation from "./SubmitConfirmation";

export const metadata = {
  title: "申請内容を確認｜ひらいずみ志業ポータル",
  description: "利用申請の入力内容と料金見込みを確認します。",
};

function firstQueryValue(value) {
  return Array.isArray(value) ? value[0] : value;
}

export default async function CampApplicationConfirmPage({ params, searchParams }) {
  const { applicationId } = await params;
  const query = (await searchParams) ?? {};
  const kind = await getUserApplicationUsageType(applicationId, `/user/applications/${applicationId}/confirm`);
  if (kind.usageType === "community_group") {
    const result = await getGroupParticipantApplication(applicationId, "confirm");
    if (result.error || !result.application) {
      return <PageShell title="団体参加者の申請を確認"><AlertMessage tone="error" title="申請内容を確認できませんでした"><p>{errorMessage(result.error)}</p></AlertMessage>
        <LinkButton href={result.application ? `/user/applications/${applicationId}/edit` : "/user/applications"} fullWidthOnMobile>{result.application ? "入力へ戻る" : "申請一覧へ戻る"}</LinkButton></PageShell>;
    }
    return <PageShell title="団体参加者の申請を確認" description="本人情報と団体の利用内容に間違いがないか確認してから提出してください。">
      {firstQueryValue(query.error) && <AlertMessage tone="error" title="申請を提出できませんでした"><p>{errorMessage(firstQueryValue(query.error))}</p></AlertMessage>}
      <GroupParticipantReview application={result.application} />
      <SubmitConfirmation applicationId={applicationId} usageType="community_group" updatedAt={result.application.updated_at} submissionKey={crypto.randomUUID()} />
    </PageShell>;
  }
  if (kind.usageType === "community_individual") {
    const result = await getCommunityApplication(applicationId, "confirm");
    if (result.error || !result.application) {
      return <PageShell title="地域活動の個人申請を確認"><AlertMessage tone="error" title="申請内容を確認できませんでした"><p>{errorMessage(result.error)}</p></AlertMessage>
        <LinkButton href={result.application ? `/user/applications/${applicationId}/edit` : "/user/applications"} fullWidthOnMobile>{result.application ? "入力へ戻る" : "申請一覧へ戻る"}</LinkButton></PageShell>;
    }
    return <PageShell title="地域活動の個人申請を確認" description="入力内容に間違いがないか確認してから提出してください。">
      <CommunityApplicationReview application={result.application} />
      <SubmitConfirmation applicationId={applicationId} usageType="community_individual" updatedAt={result.application.updated_at} submissionKey={crypto.randomUUID()} />
    </PageShell>;
  }
  const actionError = firstQueryValue(query.error);
  const { error, application } = await getCampApplicationForConfirm(applicationId);

  if (error || !application) {
    const editPath = application
      ? `/user/applications/${application.id}/edit`
      : "/user/applications";
    return (
      <PageShell title="キャンプ申請を確認">
        <AlertMessage tone="error" title="申請内容を確認できませんでした">
          <p>{errorMessage(error)}</p>
        </AlertMessage>
        <LinkButton href={editPath} fullWidthOnMobile>
          {application ? "入力へ戻る" : "申請一覧へ戻る"}
        </LinkButton>
      </PageShell>
    );
  }

  return (
    <PageShell
      title="キャンプ申請を確認"
      description="入力内容に間違いがないか確認してから提出してください。"
    >
      {actionError && (
        <AlertMessage tone="error" title="申請を提出できませんでした">
          <p>{errorMessage(actionError)}</p>
        </AlertMessage>
      )}
      <CampApplicationReview application={application} />
      <SubmitConfirmation applicationId={application.id} />
    </PageShell>
  );
}
