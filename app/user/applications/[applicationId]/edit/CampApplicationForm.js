"use client";

import { useActionState, useEffect, useRef } from "react";
import { saveCampApplicationDraft } from "@/app/actions/camp-applications";
import { uploadGuardianConsent } from "@/app/actions/guardian-consent";
import AlertMessage, {
  errorAlertItems,
} from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import LinkButton from "@/app/components/LinkButton";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import { ELIGIBLE_ROSTER_PDF_LIMITS } from "@/utils/camp-applications/validation";
import styles from "./page.module.css";

const FILE_ERROR_CODES = new Set([
  "file-required",
  "invalid-size",
  "invalid-type",
  "invalid-content",
  "upload-failed",
]);

function formatFileSize(bytes) {
  if (!Number.isInteger(bytes) || bytes < 1) return "";
  if (bytes < 1024 * 1024) return `${Math.ceil(bytes / 1024)}KB`;
  return `${(bytes / (1024 * 1024)).toFixed(1)}MB`;
}

function fileTypeLabel(mimeType) {
  return {
    "application/pdf": "PDF",
    "image/jpeg": "JPEG",
    "image/png": "PNG",
  }[mimeType] ?? "ファイル";
}

export default function CampApplicationForm({
  applicationId,
  initialFields,
  consent,
  download,
  uploadErrorCode,
  roomAssignmentMode,
  inputVersion,
  nameContext,
}) {
  const [state, formAction, pending] = useActionState(
    saveCampApplicationDraft,
    { error: null, fields: initialFields, fieldErrors: {} },
  );
  const summaryRef = useRef(null);
  const fields = state?.fields ?? initialFields;
  const eligibleRoster = roomAssignmentMode === "eligible_roster";
  const limits = eligibleRoster
    ? ELIGIBLE_ROSTER_PDF_LIMITS
    : {
        applicantName: 100,
        applicantAddress: 500,
        applicantPhone: 20,
        emergencyContactName: 100,
        emergencyContactAddress: 500,
        emergencyContactPhone: 20,
        usagePurpose: 2000,
        notes: 2000,
      };

  useEffect(() => {
    if (!state?.error) return;
    const firstName = Object.keys(state.fieldErrors ?? {})[0];
    const target = firstName ? document.getElementById(firstName) : null;
    (target ?? summaryRef.current)?.focus();
  }, [state]);

  return (
    <>
      <form className={styles.form} action={formAction} noValidate>
      <input type="hidden" name="applicationId" value={applicationId} />
      <input type="hidden" name="roomAssignmentMode" value={roomAssignmentMode} />
      {eligibleRoster && <input type="hidden" name="inputVersion" value={inputVersion} />}

      {state?.error && (
        <div ref={summaryRef} tabIndex={-1} className={styles.focusTarget}>
          <AlertMessage
            tone="error"
            title="入力内容を保存できませんでした"
            items={errorAlertItems(state.fieldErrors)}
          >
            <p>{errorMessage(state.error)}</p>
          </AlertMessage>
        </div>
      )}

      <fieldset className={styles.group}>
        <legend className={styles.groupTitle}>申請者情報</legend>
        <p className={styles.groupDescription}>
          申請者本人の情報を入力してください。プロフィールの登録内容を初期表示しています。メールアドレスはログイン中のアカウント情報を使用します。
        </p>
        {eligibleRoster && (
          <div className={styles.nameSyncNotice}>
            <p><strong>この申請で使用する正式な氏名</strong></p>
            <p>PDFを確認して提出した時点で、入力した氏名をプロフィール氏名と町の管理用氏名へ同時に反映します。</p>
            <dl>
              <div><dt>現在のプロフィール氏名</dt><dd>{nameContext.profileName || "未登録"}</dd></div>
              <div><dt>現在の管理用氏名</dt><dd>{nameContext.managementName || "未登録"}</dd></div>
            </dl>
          </div>
        )}
        <div className={styles.fields}>
          <FormField
            id="applicantName"
            name="applicantName"
            label="氏名"
            required
            maxLength={limits.applicantName}
            autoComplete="name"
            defaultValue={fields.applicantName}
            error={state?.fieldErrors?.applicantName}
          />
          <FormField
            id="applicantAddress"
            name="applicantAddress"
            label="住所"
            required
            maxLength={limits.applicantAddress}
            autoComplete="street-address"
            defaultValue={fields.applicantAddress}
            error={state?.fieldErrors?.applicantAddress}
          />
          <FormField
            id="applicantPhone"
            name="applicantPhone"
            label="電話番号"
            required
            maxLength={limits.applicantPhone}
            type="tel"
            inputMode="tel"
            autoComplete="tel"
            hint="数字、ハイフン、丸括弧を使用できます。"
            defaultValue={fields.applicantPhone}
            error={state?.fieldErrors?.applicantPhone}
          />
        </div>
      </fieldset>

      <fieldset className={styles.group}>
        <legend className={styles.groupTitle}>緊急連絡先</legend>
        <p className={styles.groupDescription}>
          緊急時に連絡できる方の情報を入力してください。
        </p>
        <div className={styles.fields}>
          <FormField
            id="emergencyContactName"
            name="emergencyContactName"
            label="緊急連絡先の氏名"
            required
            maxLength={limits.emergencyContactName}
            defaultValue={fields.emergencyContactName}
            error={state?.fieldErrors?.emergencyContactName}
          />
          <FormField
            id="emergencyContactAddress"
            name="emergencyContactAddress"
            label="緊急連絡先の住所"
            required
            maxLength={limits.emergencyContactAddress}
            defaultValue={fields.emergencyContactAddress}
            error={state?.fieldErrors?.emergencyContactAddress}
          />
          <FormField
            id="emergencyContactPhone"
            name="emergencyContactPhone"
            label="緊急連絡先の電話番号"
            required
            maxLength={limits.emergencyContactPhone}
            type="tel"
            inputMode="tel"
            hint="数字、ハイフン、丸括弧を使用できます。"
            defaultValue={fields.emergencyContactPhone}
            error={state?.fieldErrors?.emergencyContactPhone}
          />
        </div>
      </fieldset>

      <fieldset className={styles.group}>
        <legend className={styles.groupTitle}>利用内容</legend>
        <div className={styles.fields}>
          <FormField
            as="select"
            id="usagePlace"
            name="usagePlace"
            label="使用箇所"
            required
            options={[
              {
                value: "common_and_second_floor",
                label: "共用部分及び2階個室",
              },
            ]}
            defaultValue={fields.usagePlace}
            error={state?.fieldErrors?.usagePlace}
          />
          <FormField
            as="textarea"
            id="usagePurpose"
            name="usagePurpose"
            label="使用目的"
            required
            rows={5}
            maxLength={limits.usagePurpose}
            hint="キャンプ参加中のシェアハウス利用目的を入力してください。"
            defaultValue={fields.usagePurpose}
            error={state?.fieldErrors?.usagePurpose}
          />
          <FormField
            as="textarea"
            id="notes"
            name="notes"
            label="特記事項"
            rows={4}
            maxLength={limits.notes}
            hint="町へ伝えておきたいことがある場合に入力してください。"
            defaultValue={fields.notes}
            error={state?.fieldErrors?.notes}
          />
        </div>
      </fieldset>

      <fieldset className={styles.group}>
        <legend className={styles.groupTitle}>確認事項</legend>
        <div className={styles.fields}>
          <FormField
            as="radio"
            id="guardianConsentRequired"
            name="guardianConsentRequired"
            label="未成年者、または18歳の高校生に該当しますか"
            required
            hint="該当する場合は、保護者同意書の添付が必要です。"
            options={[
              { value: "true", label: "該当する" },
              { value: "false", label: "該当しない" },
            ]}
            defaultValue={fields.guardianConsentRequired}
            error={state?.fieldErrors?.guardianConsentRequired}
          />
          {eligibleRoster ? (
            <p className={styles.groupDescription}>部屋は町が事前に割り当てた内容を確認用PDFへ印字します。この画面から部屋の希望や割当は変更できません。</p>
          ) : (
            <FormField
              as="radio"
              id="requestedRoomPreference"
              name="requestedRoomPreference"
              label="部屋の希望"
              required
              hint="希望は部屋割りの参考情報です。個室を保証するものではありません。"
              options={[
                { value: "shared_ok", label: "相部屋可" },
                { value: "private_requested", label: "個室希望" },
              ]}
              defaultValue={fields.requestedRoomPreference}
              error={state?.fieldErrors?.requestedRoomPreference}
            />
          )}
        </div>
      </fieldset>

      <div className={styles.actions}>
        <SubmitButton
          name="intent"
          value="save"
          variant="secondary"
          pending={pending}
          pendingLabel="保存中…"
          fullWidthOnMobile
        >
          下書き保存
        </SubmitButton>
        <SubmitButton
          name="intent"
          value="confirm"
          pending={pending}
          pendingLabel="保存中…"
          fullWidthOnMobile
        >
          確認へ進む
        </SubmitButton>
      </div>
      <p className={styles.actionNote}>
        自動保存はされません。入力途中の場合は「下書き保存」を押してください。
      </p>
      </form>

      <section className={styles.consent} aria-labelledby="consent-heading">
        <div className={styles.sectionHeader}>
          <h2 className={styles.sectionTitle} id="consent-heading">
            保護者同意書
          </h2>
          <p className={styles.sectionDescription}>
            未成年者、または18歳の高校生に該当する場合に添付してください。
            入力途中の場合は、添付前に上の「下書き保存」を押してください。
          </p>
        </div>

        {consent && (
          <div className={styles.attached}>
            <p className={styles.attachedTitle}>添付済み</p>
            <p>
              {fileTypeLabel(consent.mimeType)}、
              {formatFileSize(consent.sizeBytes)}
            </p>
            {download.url ? (
              <LinkButton href={download.url}>添付ファイルを確認</LinkButton>
            ) : (
              <p className={styles.downloadError}>
                {errorMessage(download.error)}
              </p>
            )}
          </div>
        )}

        <form className={styles.uploadForm} action={uploadGuardianConsent}>
          <input type="hidden" name="applicationId" value={applicationId} />
          <FormField
            id="guardianConsentFile"
            name="guardianConsentFile"
            label={consent ? "差し替えるファイル" : "添付するファイル"}
            type="file"
            accept="application/pdf,image/jpeg,image/png"
            hint="PDF・JPEG・PNG、5MB以下。1申請につき1ファイルです。"
            error={
              state?.fieldErrors?.guardianConsentFile ??
              (FILE_ERROR_CODES.has(uploadErrorCode)
                ? uploadErrorCode
                : undefined)
            }
          />
          <SubmitButton
            variant="secondary"
            pendingLabel="ファイルを保存中…"
            fullWidthOnMobile
          >
            {consent ? "ファイルを差し替える" : "ファイルを添付する"}
          </SubmitButton>
        </form>
      </section>
    </>
  );
}
