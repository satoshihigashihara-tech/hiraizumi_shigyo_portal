import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge from "@/app/components/StatusBadge";
import { formatPeriod } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { getCommunityApplicationCancellation } from "@/utils/community-applications/queries";
import CancellationForm from "./CancellationForm";
import styles from "../page.module.css";

export const metadata = { title: "利用申請を取り消す｜ひらいずみ志業ポータル" };

export default async function CommunityApplicationCancellationPage({ params }) {
  const { applicationId } = await params;
  const result = await getCommunityApplicationCancellation(applicationId);
  if (result.error === "not-found") notFound();

  const application = result.application;
  return (
    <PageShell title="利用申請を取り消す" description="取消理由と手続き後の扱いを確認してください。">
      {result.error || !application ? (
        <AlertMessage tone="error" title="取消の受付状態を確認できませんでした">
          <p>{errorMessage(result.error)}</p>
        </AlertMessage>
      ) : (
        <>
          <StatusBadge kind="application" value={application.status} showKind />
          <section className={`${styles.panel} ${application.can_request ? styles.dangerPanel : ""}`} aria-labelledby="cancellation-heading">
            <h2 id="cancellation-heading">取消する申請</h2>
            <dl className={styles.facts}>
              <div><dt>利用期間</dt><dd>{formatPeriod(application.start_date, application.end_date)}</dd></div>
              {application.cancel_reason && <div><dt>登録済みの取消理由</dt><dd>{application.cancel_reason}</dd></div>}
            </dl>
            {application.can_request ? (
              <>
                <AlertMessage tone="warning" title="取消はまだ確定しません">
                  <p>申請後、町の職員が確認するまで利用枠・部屋・料金は保持されます。</p>
                </AlertMessage>
                <CancellationForm applicationId={application.id} updatedAt={application.updated_at} />
              </>
            ) : (
              <AlertMessage tone="info" title="画面から取消申請できません">
                <p>{application.status === "cancellation_requested"
                  ? "取消申請を町の職員が確認しています。"
                  : application.status === "cancelled"
                    ? "この申請は取消済みです。"
                    : application.stay_status === "staying" || application.stay_status === "moved_out"
                      ? "利用開始後の変更は、町の担当へお問い合わせください。"
                      : "現在の申請状態では取消を受け付けられません。町の担当へお問い合わせください。"}</p>
              </AlertMessage>
            )}
          </section>
        </>
      )}
      <div className={styles.actions}>
        <LinkButton href={`/user/applications/${applicationId}`} fullWidthOnMobile>申請詳細へ戻る</LinkButton>
        <LinkButton href="/user/applications" fullWidthOnMobile>申請一覧へ戻る</LinkButton>
      </div>
    </PageShell>
  );
}
