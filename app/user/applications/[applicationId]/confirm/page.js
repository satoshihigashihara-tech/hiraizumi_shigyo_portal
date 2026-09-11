import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { errorMessage } from "@/app/components/messages";
import CampApplicationReview from "../CampApplicationReview";
import { getCampApplicationForConfirm } from "@/utils/camp-applications/queries";
import SubmitConfirmation from "./SubmitConfirmation";

export const metadata = {
  title: "キャンプ申請を確認｜ひらいずみ志業ポータル",
  description: "キャンプ利用申請の入力内容と料金見込みを確認します。",
};

function firstQueryValue(value) {
  return Array.isArray(value) ? value[0] : value;
}

export default async function CampApplicationConfirmPage({ params, searchParams }) {
  const { applicationId } = await params;
  const query = (await searchParams) ?? {};
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
