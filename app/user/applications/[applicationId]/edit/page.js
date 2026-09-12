import { createGuardianConsentDownloadUrl, uploadGuardianConsent } from "@/app/actions/guardian-consent";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import {
  formatDeadline,
  formatJstDateTime,
  formatPeriod,
} from "@/app/components/format";
import { getCampApplicationForEdit } from "@/utils/camp-applications/queries";
import { getCommunityApplication } from "@/utils/community-applications/queries";
import { getGroupParticipantApplication } from "@/utils/group-participants/queries";
import { getUserApplicationUsageType } from "@/utils/user-applications/queries";
import CampApplicationForm from "./CampApplicationForm";
import CommunityApplicationForm from "./CommunityApplicationForm";
import GroupParticipantForm from "./GroupParticipantForm";
import styles from "./page.module.css";

export const metadata = {
  title: "申請内容を入力｜ひらいずみ志業ポータル",
  description: "利用申請の内容を入力し、下書きを保存します。",
};

function firstQueryValue(value) {
  return Array.isArray(value) ? value[0] : value;
}

export default async function CampApplicationEditPage({ params, searchParams }) {
  const { applicationId } = await params;
  const query = (await searchParams) ?? {};
  const kind = await getUserApplicationUsageType(applicationId, `/user/applications/${applicationId}/edit`);
  if (kind.usageType === "community_group") {
    const result = await getGroupParticipantApplication(applicationId, "edit");
    const application = result.application;
    const download = application?.has_consent ? await createGuardianConsentDownloadUrl(applicationId) : { error: null, url: null };
    const errorCode = firstQueryValue(query.error);
    return <PageShell title="団体参加者の申請を入力" description="本人と緊急連絡先の情報を入力し、確認画面へ進んでください。">
      {firstQueryValue(query.saved) === "1" && <AlertMessage tone="success" title="下書きを保存しました" />}
      {firstQueryValue(query.uploaded) === "1" && <AlertMessage tone="success" title="保護者同意書を保存しました" />}
      {errorCode && <AlertMessage tone="error" title="保護者同意書を保存できませんでした"><p>{errorMessage(errorCode)}</p></AlertMessage>}
      {result.error && <AlertMessage tone="error" title="申請を開けませんでした"><p>{errorMessage(result.error)}</p></AlertMessage>}
      {application?.status === "revision_requested" && <AlertMessage tone="warning" title="申請内容の修正が必要です">
        <p>{application.decision_reason || "町からの案内を確認して修正してください。"}</p>
        {application.active_deadline && <p>再提出の期限：{formatDeadline(application.active_deadline)}</p>}
      </AlertMessage>}
      {application && <section className={styles.summary} aria-labelledby="group-participant-summary-heading">
        <h2 className={styles.summaryTitle} id="group-participant-summary-heading">{application.group_name}</h2>
        <dl className={styles.summaryFacts}>
          <div><dt>利用期間</dt><dd>{formatPeriod(application.start_date, application.end_date)}</dd></div>
          <div><dt>団体の利用内容</dt><dd>代表者が登録済み（変更できません）</dd></div>
        </dl>
        <p className={styles.summaryNote}>この画面では、あなた自身の情報だけを入力します。他の参加者の個人情報は表示されません。</p>
      </section>}
      {!result.error && application?.can_edit && <>
        <GroupParticipantForm applicationId={application.id} updatedAt={application.updated_at} initialFields={application.fields} />
        <section className={styles.consent} aria-labelledby="group-participant-consent-heading">
          <div className={styles.sectionHeader}><h2 className={styles.sectionTitle} id="group-participant-consent-heading">保護者同意書</h2>
            <p className={styles.sectionDescription}>該当する場合にPDF・JPEG・PNGのいずれかを添付してください。添付前に上の下書きを保存してください。</p></div>
          {application.has_consent && <div className={styles.attached}><p className={styles.attachedTitle}>添付済み</p>
            {download.url ? <LinkButton href={download.url}>添付ファイルを確認</LinkButton> : <p className={styles.downloadError}>{errorMessage(download.error)}</p>}</div>}
          <form className={styles.uploadForm} action={uploadGuardianConsent}>
            <input type="hidden" name="applicationId" value={application.id} />
            <input type="hidden" name="updatedAt" value={application.updated_at} />
            <FormField id="guardianConsentFile" name="guardianConsentFile" label={application.has_consent ? "差し替えるファイル" : "添付するファイル"} type="file" accept="application/pdf,image/jpeg,image/png" hint="PDF・JPEG・PNG、5MB以下。1申請につき1ファイルです。" />
            <SubmitButton variant="secondary" pendingLabel="ファイルを保存中…" fullWidthOnMobile>{application.has_consent ? "ファイルを差し替える" : "ファイルを添付する"}</SubmitButton>
          </form>
        </section>
      </>}
      <div className={styles.backLink}><LinkButton href="/user/applications" fullWidthOnMobile>申請一覧へ戻る</LinkButton></div>
    </PageShell>;
  }
  if (kind.usageType === "community_individual") {
    const result = await getCommunityApplication(applicationId, "edit");
    const application = result.application;
    const download = application?.has_consent ? await createGuardianConsentDownloadUrl(applicationId) : { error: null, url: null };
    const errorCode = firstQueryValue(query.error);
    return <PageShell title="利用申請を入力" description="入力内容を保存し、確認画面へ進んでください。">
      {firstQueryValue(query.saved) === "1" && <AlertMessage tone="success" title="下書きを保存しました" />}
      {firstQueryValue(query.uploaded) === "1" && <AlertMessage tone="success" title="保護者同意書を保存しました" />}
      {errorCode && <AlertMessage tone="error" title="保護者同意書を保存できませんでした"><p>{errorMessage(errorCode)}</p></AlertMessage>}
      {result.error && <AlertMessage tone="error" title="申請を開けませんでした"><p>{errorMessage(result.error)}</p></AlertMessage>}
      {application?.status === "revision_requested" && <AlertMessage tone="warning" title="申請内容の修正が必要です">
        <p>{application.decision_reason || "町からの案内を確認して修正してください。"}</p>
        {application.revision_due_at && <p>修正期限：{formatJstDateTime(application.revision_due_at)}</p>}
      </AlertMessage>}
      {!result.error && application?.can_edit && <>
        <CommunityApplicationForm applicationId={application.id} updatedAt={application.updated_at} initialFields={application.fields} />
        <section className={styles.consent} aria-labelledby="community-consent-heading">
          <div className={styles.sectionHeader}><h2 className={styles.sectionTitle} id="community-consent-heading">保護者同意書</h2>
            <p className={styles.sectionDescription}>該当する場合にPDF・JPEG・PNGのいずれかを添付してください。添付前に上の下書きを保存してください。</p></div>
          {application.has_consent && <div className={styles.attached}><p className={styles.attachedTitle}>添付済み</p>
            {download.url ? <LinkButton href={download.url}>添付ファイルを確認</LinkButton> : <p className={styles.downloadError}>{errorMessage(download.error)}</p>}</div>}
          <form className={styles.uploadForm} action={uploadGuardianConsent}>
            <input type="hidden" name="applicationId" value={application.id} />
            <input type="hidden" name="updatedAt" value={application.updated_at} />
            <FormField id="guardianConsentFile" name="guardianConsentFile" label={application.has_consent ? "差し替えるファイル" : "添付するファイル"} type="file" accept="application/pdf,image/jpeg,image/png" hint="PDF・JPEG・PNG、5MB以下。1申請につき1ファイルです。" />
            <SubmitButton variant="secondary" pendingLabel="ファイルを保存中…" fullWidthOnMobile>{application.has_consent ? "ファイルを差し替える" : "ファイルを添付する"}</SubmitButton>
          </form>
        </section>
      </>}
      <div className={styles.backLink}><LinkButton href="/user/applications" fullWidthOnMobile>申請一覧へ戻る</LinkButton></div>
    </PageShell>;
  }
  const errorCode = firstQueryValue(query.error);
  const saved = firstQueryValue(query.saved) === "1";
  const uploaded = firstQueryValue(query.uploaded) === "1";
  const { error, application } = await getCampApplicationForEdit(applicationId);

  if (error || !application) {
    return (
      <PageShell title="キャンプ申請を入力">
        <AlertMessage tone="error" title="申請を開けませんでした">
          <p>{errorMessage(error)}</p>
        </AlertMessage>
        <LinkButton href="/user/applications" fullWidthOnMobile>
          申請一覧へ戻る
        </LinkButton>
      </PageShell>
    );
  }

  const download = application.consent
    ? await createGuardianConsentDownloadUrl(application.id)
    : { error: null, url: null };
  const editable =
    application.status === "draft" ||
    application.status === "revision_requested";

  return (
    <PageShell
      title="キャンプ申請を入力"
      description="入力内容を保存し、確認画面へ進んでください。"
    >
      {saved && (
        <AlertMessage tone="success" title="下書きを保存しました" />
      )}
      {uploaded && (
        <AlertMessage tone="success" title="保護者同意書を保存しました" />
      )}
      {errorCode && (
        <AlertMessage tone="error" title="保護者同意書を保存できませんでした">
          <p>{errorMessage(errorCode)}</p>
        </AlertMessage>
      )}

      {application.status === "revision_requested" && (
        <AlertMessage tone="warning" title="申請内容の修正が必要です">
          <p>
            {application.revisionReason ||
              "町からの案内を確認して修正してください。"}
          </p>
          {application.revisionDueAt && (
            <p>修正期限：{formatJstDateTime(application.revisionDueAt)}</p>
          )}
        </AlertMessage>
      )}

      {!editable && (
        <AlertMessage tone="warning" title="この申請は編集できません">
          <p>
            現在の申請状態では内容を変更できません。申請詳細をご確認ください。
          </p>
        </AlertMessage>
      )}

      <section className={styles.summary} aria-labelledby="camp-summary-heading">
        <h2 className={styles.summaryTitle} id="camp-summary-heading">
          {application.campName}
        </h2>
        <dl className={styles.summaryFacts}>
          <div>
            <dt>利用期間</dt>
            <dd>{formatPeriod(application.startDate, application.endDate)}</dd>
          </div>
          <div>
            <dt>日程変更</dt>
            <dd>できません</dd>
          </div>
        </dl>
        <p className={styles.summaryNote}>
          キャンプの全期間が部屋確保と料金計算の対象です。一時的に不在となる日があっても期間は変わりません。
        </p>
      </section>

      {editable && (
        <CampApplicationForm
          applicationId={application.id}
          initialFields={application.fields}
          consent={application.consent}
          download={download}
          uploadErrorCode={errorCode}
        />
      )}

      <div className={styles.backLink}>
        <LinkButton href="/user/applications" fullWidthOnMobile>
          申請一覧へ戻る
        </LinkButton>
      </div>
    </PageShell>
  );
}
