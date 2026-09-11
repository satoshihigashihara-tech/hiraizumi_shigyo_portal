import { createGuardianConsentDownloadUrl } from "@/app/actions/guardian-consent";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { errorMessage } from "@/app/components/messages";
import {
  formatJstDateTime,
  formatPeriod,
} from "@/app/components/format";
import { getCampApplicationForEdit } from "@/utils/camp-applications/queries";
import CampApplicationForm from "./CampApplicationForm";
import styles from "./page.module.css";

export const metadata = {
  title: "キャンプ申請を入力｜ひらいずみ志業ポータル",
  description: "キャンプ利用申請の内容を入力し、下書きを保存します。",
};

function firstQueryValue(value) {
  return Array.isArray(value) ? value[0] : value;
}

export default async function CampApplicationEditPage({ params, searchParams }) {
  const { applicationId } = await params;
  const query = (await searchParams) ?? {};
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
