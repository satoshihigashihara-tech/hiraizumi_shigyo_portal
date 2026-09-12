import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge from "@/app/components/StatusBadge";
import { formatJstDate, jstToday } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { getCommunityApplicationExtensionSource } from "@/utils/community-applications/queries";
import ExtensionForm from "./ExtensionForm";
import styles from "../page.module.css";

export const metadata = { title: "継続申請｜ひらいずみ志業ポータル" };

function addDays(date, days) {
  const value = new Date(`${date}T00:00:00Z`);
  value.setUTCDate(value.getUTCDate() + days);
  return value.toISOString().slice(0, 10);
}

export default async function CommunityApplicationExtensionPage({ params }) {
  const { applicationId } = await params;
  const result = await getCommunityApplicationExtensionSource(applicationId);
  if (result.error === "not-found") notFound();

  const application = result.application;
  const maximumEndDate = application?.extension_start_date
    ? [addDays(application.extension_start_date, 14), addDays(jstToday(), 60)].sort()[0]
    : null;
  return (
    <PageShell title="継続申請" description="元の申請を変更せず、追加期間を別の申請として作成します。">
      {result.error || !application ? (
        <AlertMessage tone="error" title="継続申請の受付状態を確認できませんでした">
          <p>{errorMessage(result.error)}</p>
        </AlertMessage>
      ) : (
        <>
          <StatusBadge kind="application" value={application.status} showKind />
          <section className={styles.panel} aria-labelledby="extension-heading">
            <h2 id="extension-heading">継続する期間</h2>
            <dl className={styles.facts}>
              <div><dt>元の利用終了日</dt><dd>{formatJstDate(application.end_date)}</dd></div>
              <div><dt>継続開始日</dt><dd>{formatJstDate(application.extension_start_date)}</dd></div>
            </dl>
            {application.can_extend ? (
              <>
                <AlertMessage tone="info" title="別の申請を作成します">
                  <p>元の申請内容は変更しません。継続分には別の審査・料金・部屋・受付番号が設定されます。</p>
                </AlertMessage>
                <ExtensionForm
                  extensionId={crypto.randomUUID()}
                  originalApplicationId={application.id}
                  startDate={application.extension_start_date}
                  maximumEndDate={maximumEndDate}
                />
              </>
            ) : application.existing_extension_id ? (
              <AlertMessage tone="info" title="継続申請はすでに作成されています">
                <p>新しい申請を重ねて作らず、作成済みの継続申請を確認してください。</p>
                <LinkButton href={`/user/applications/${application.existing_extension_id}`}>作成済みの継続申請を見る</LinkButton>
              </AlertMessage>
            ) : (
              <AlertMessage tone="info" title="現在は継続申請できません">
                <p>申請状態または日程を確認し、必要な場合は町の担当へお問い合わせください。</p>
              </AlertMessage>
            )}
          </section>
        </>
      )}
      <div className={styles.actions}>
        <LinkButton href={`/user/applications/${applicationId}`} fullWidthOnMobile>元の申請詳細へ戻る</LinkButton>
        <LinkButton href="/user/applications" fullWidthOnMobile>申請一覧へ戻る</LinkButton>
      </div>
    </PageShell>
  );
}
