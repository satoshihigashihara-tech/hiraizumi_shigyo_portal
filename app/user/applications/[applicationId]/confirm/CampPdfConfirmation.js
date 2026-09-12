"use client";

import { useActionState, useState } from "react";
import {
  requestCampApplicationPdf,
  submitCampApplication,
} from "@/app/actions/camp-applications";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "../application-view.module.css";

async function submitState(_previousState, formData) {
  return submitCampApplication(formData);
}

function PdfRequest({ applicationId, inputVersion, requestKey, pdfState }) {
  const messages = {
    generating: {
      tone: "info",
      title: "確認用PDFを生成しています",
      body: "生成には少し時間がかかります。しばらくしてからこの画面を再読み込みしてください。",
    },
    failed: {
      tone: "warning",
      title: "確認用PDFを生成できませんでした",
      body: "入力内容は保存されています。再生成しても解決しない場合は町の担当へお問い合わせください。",
    },
    stale: {
      tone: "warning",
      title: "確認用PDFが古くなりました",
      body: "入力・部屋割り・テンプレートのいずれかが変更されています。現在の内容からPDFを作り直してください。",
    },
  };
  const notice = messages[pdfState];

  return (
    <section className={styles.submissionPanel} aria-labelledby="camp-pdf-heading">
      <div className={styles.sectionHeading}>
        <h2 className={styles.sectionTitle} id="camp-pdf-heading">使用許可申請書PDF</h2>
        <p>保存した入力と町が割り当てた部屋から、確認用の1ページPDFを生成します。</p>
      </div>
      {notice && <AlertMessage tone={notice.tone} title={notice.title}><p>{notice.body}</p></AlertMessage>}
      {pdfState === "generating" && (
        <LinkButton href={`/user/applications/${applicationId}/confirm`} variant="secondary" fullWidthOnMobile>
          生成状況を更新する
        </LinkButton>
      )}
      {pdfState !== "generating" && (
        <form action={requestCampApplicationPdf}>
          <input type="hidden" name="applicationId" value={applicationId} />
          <input type="hidden" name="inputVersion" value={inputVersion} />
          <input type="hidden" name="requestKey" value={requestKey} />
          <SubmitButton pendingLabel="生成を依頼中…" fullWidthOnMobile>
            {pdfState === "not_requested" ? "確認用PDFを生成する" : "確認用PDFを再生成する"}
          </SubmitButton>
        </form>
      )}
      <LinkButton href={`/user/applications/${applicationId}/edit`} variant="secondary" fullWidthOnMobile>
        入力へ戻る
      </LinkButton>
    </section>
  );
}

export default function CampPdfConfirmation({
  applicationId,
  inputVersion,
  pdfState,
  pdfVersionId,
  requestKey,
  submissionKey,
  profileName,
  managementName,
  applicantName,
}) {
  const [confirmed, setConfirmed] = useState(false);
  const [state, formAction, pending] = useActionState(submitState, { error: null });

  if (pdfState !== "ready" || !pdfVersionId) {
    return <PdfRequest applicationId={applicationId} inputVersion={inputVersion} requestKey={requestKey} pdfState={pdfState} />;
  }

  return (
    <section className={styles.submissionPanel} aria-labelledby="camp-pdf-heading">
      <div className={styles.sectionHeading}>
        <h2 className={styles.sectionTitle} id="camp-pdf-heading">使用許可申請書PDFを確認</h2>
        <p>下のPDFと提出対象は同じ不変版です。1ページすべてを確認してから提出してください。</p>
      </div>
      <iframe
        className={styles.pdfFrame}
        src={`/api/camp/application-pdfs/${pdfVersionId}`}
        title="提出する使用許可申請書PDF"
      />
      <LinkButton href={`/api/camp/application-pdfs/${pdfVersionId}`} variant="secondary" fullWidthOnMobile>
        PDFを画面全体で開く
      </LinkButton>
      <div className={styles.nameSyncSummary}>
        <p><strong>提出時の氏名同期</strong></p>
        <p>PDFの氏名「{applicantName}」を、プロフィール氏名と町の管理用氏名へ同時に反映します。</p>
        <dl>
          <div><dt>現在のプロフィール氏名</dt><dd>{profileName || "未登録"}</dd></div>
          <div><dt>現在の管理用氏名</dt><dd>{managementName || "未登録"}</dd></div>
        </dl>
      </div>
      <form action={formAction}>
        <input type="hidden" name="applicationId" value={applicationId} />
        <input type="hidden" name="pdfVersionId" value={pdfVersionId} />
        <input type="hidden" name="inputVersion" value={inputVersion} />
        <input type="hidden" name="submissionKey" value={submissionKey} />
        {state?.error && <AlertMessage tone="error" title="申請を提出できませんでした"><p>{errorMessage(state.error)}</p></AlertMessage>}
        <label className={styles.confirmationLabel}>
          <input
            type="checkbox"
            name="confirmed"
            value="true"
            checked={confirmed}
            onChange={(event) => setConfirmed(event.target.checked)}
            required
          />
          <span>表示された1ページのPDFが、入力内容・氏名・利用期間・部屋を含む提出書類であることを確認しました</span>
        </label>
        <p className={styles.submissionNote}>提出時に期限・資格・所有権と各版をもう一度確認します。この操作だけでは利用は確定しません。</p>
        <div className={styles.actions}>
          <LinkButton href={`/user/applications/${applicationId}/edit`} variant="secondary" fullWidthOnMobile>入力へ戻る</LinkButton>
          <SubmitButton disabled={!confirmed} pending={pending} pendingLabel="提出中…" fullWidthOnMobile>確認したPDFを提出する</SubmitButton>
        </div>
      </form>
    </section>
  );
}
