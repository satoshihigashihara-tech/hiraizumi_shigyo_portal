import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge from "@/app/components/StatusBadge";
import { formatJstDateTime } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { getCampApplicationForComplete } from "@/utils/camp-applications/queries";
import { getCommunityApplication } from "@/utils/community-applications/queries";
import { getGroupParticipantApplication } from "@/utils/group-participants/queries";
import { getUserApplicationUsageType } from "@/utils/user-applications/queries";
import styles from "../application-view.module.css";

export const metadata = {
  title: "申請受付完了｜ひらいずみ志業ポータル",
  description: "利用申請の受付番号と現在の状態を確認します。",
};

export default async function CampApplicationCompletePage({ params }) {
  const { applicationId } = await params;
  const kind = await getUserApplicationUsageType(applicationId, `/user/applications/${applicationId}/complete`);
  if (kind.usageType === "community_group") {
    const result = await getGroupParticipantApplication(applicationId, "complete");
    if (result.error || !result.application) {
      return <PageShell title="団体参加者申請の受付結果"><AlertMessage tone="error" title="受付結果を確認できませんでした"><p>{errorMessage(result.error)}</p></AlertMessage>
        <LinkButton href="/user/applications" fullWidthOnMobile>申請一覧へ戻る</LinkButton></PageShell>;
    }
    const application = result.application;
    const groupReviewStarted = application.group_status === "under_review";
    return <PageShell title="参加者申請を受け付けました" description={groupReviewStarted ? "団体の参加者全員の提出が完了し、町の審査へ進みました。" : "受付内容を控えて、ほかの参加者の提出をお待ちください。"}>
      <AlertMessage tone="info" title="この時点では利用は確定していません"><p>{groupReviewStarted ? "団体申請は町の審査中です。結果は申請詳細でご確認ください。" : "団体の参加者全員が提出すると、団体申請が町の審査へ進みます。"}</p></AlertMessage>
      <section className={styles.completePanel} aria-labelledby="receipt-heading"><h2 className={styles.completeTitle} id="receipt-heading">受付内容</h2>
        <dl className={styles.completeFacts}>
          <div><dt>団体名</dt><dd>{application.group_name}</dd></div>
          <div><dt>受付番号</dt><dd className={styles.receptionNumber}>{application.reception_number}</dd></div>
          <div><dt>提出日時</dt><dd>{formatJstDateTime(application.last_submitted_at)}</dd></div>
          <div><dt>現在の申請状態</dt><dd><StatusBadge value={application.status} showKind /></dd></div>
        </dl>
      </section>
      <div className={styles.actions}><LinkButton href={`/user/applications/${application.id}`} fullWidthOnMobile>申請詳細を見る</LinkButton><LinkButton href="/user" fullWidthOnMobile>利用者ホームへ戻る</LinkButton></div>
    </PageShell>;
  }
  if (kind.usageType === "community_individual") {
    const result = await getCommunityApplication(applicationId, "complete");
    if (result.error || !result.application) {
      return <PageShell title="利用申請の受付結果"><AlertMessage tone="error" title="受付結果を確認できませんでした"><p>{errorMessage(result.error)}</p></AlertMessage>
        <LinkButton href="/user/applications" fullWidthOnMobile>申請一覧へ戻る</LinkButton></PageShell>;
    }
    const application = result.application;
    return <PageShell title="申請を受け付けました" description="受付内容を控えて、職員からの審査結果をお待ちください。">
      <AlertMessage tone="info" title="この時点では利用は確定していません"><p>申請内容を職員が審査します。結果は申請詳細でご確認ください。</p></AlertMessage>
      <section className={styles.completePanel} aria-labelledby="receipt-heading"><h2 className={styles.completeTitle} id="receipt-heading">受付内容</h2>
        <dl className={styles.completeFacts}>
          <div><dt>受付番号</dt><dd className={styles.receptionNumber}>{application.reception_number}</dd></div>
          <div><dt>提出日時</dt><dd>{formatJstDateTime(application.last_submitted_at)}</dd></div>
          <div><dt>現在の申請状態</dt><dd><StatusBadge value={application.status} showKind /></dd></div>
        </dl>
      </section>
      <div className={styles.actions}><LinkButton href={`/user/applications/${application.id}`} fullWidthOnMobile>申請詳細を見る</LinkButton><LinkButton href="/user" fullWidthOnMobile>利用者ホームへ戻る</LinkButton></div>
    </PageShell>;
  }
  const { error, application } = await getCampApplicationForComplete(applicationId);

  if (error || !application) {
    return (
      <PageShell title="キャンプ申請の受付結果">
        <AlertMessage tone="error" title="受付結果を確認できませんでした">
          <p>{errorMessage(error)}</p>
        </AlertMessage>
        <LinkButton href="/user/applications" fullWidthOnMobile>
          申請一覧へ戻る
        </LinkButton>
      </PageShell>
    );
  }

  return (
    <PageShell
      title="申請を受け付けました"
      description="受付内容を控えて、職員からの審査結果をお待ちください。"
    >
      <AlertMessage tone="info" title="この時点では利用は確定していません">
        <p>申請内容を職員が審査します。結果は申請詳細でご確認ください。</p>
      </AlertMessage>

      <section className={styles.completePanel} aria-labelledby="receipt-heading">
        <h2 className={styles.completeTitle} id="receipt-heading">
          受付内容
        </h2>
        <dl className={styles.completeFacts}>
          <div>
            <dt>受付番号</dt>
            <dd className={styles.receptionNumber}>{application.receptionNumber}</dd>
          </div>
          <div>
            <dt>提出日時</dt>
            <dd>{formatJstDateTime(application.lastSubmittedAt)}</dd>
          </div>
          <div>
            <dt>現在の申請状態</dt>
            <dd>
              <StatusBadge value={application.status} showKind />
            </dd>
          </div>
        </dl>
      </section>

      <div className={styles.actions}>
        <LinkButton
          href={`/user/applications/${application.id}`}
          fullWidthOnMobile
        >
          申請詳細を見る
        </LinkButton>
        <LinkButton href="/user" variant="secondary" fullWidthOnMobile>
          利用者ホームへ戻る
        </LinkButton>
      </div>
    </PageShell>
  );
}
