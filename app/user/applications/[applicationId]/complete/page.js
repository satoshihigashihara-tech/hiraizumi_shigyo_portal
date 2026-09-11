import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge from "@/app/components/StatusBadge";
import { formatJstDateTime } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { getCampApplicationForComplete } from "@/utils/camp-applications/queries";
import styles from "../application-view.module.css";

export const metadata = {
  title: "キャンプ申請受付完了｜ひらいずみ志業ポータル",
  description: "キャンプ利用申請の受付番号と現在の状態を確認します。",
};

export default async function CampApplicationCompletePage({ params }) {
  const { applicationId } = await params;
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
