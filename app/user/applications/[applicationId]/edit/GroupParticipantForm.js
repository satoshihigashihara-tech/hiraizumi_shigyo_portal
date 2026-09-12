"use client";

import { useActionState, useEffect, useRef } from "react";
import { saveGroupParticipantApplication } from "@/app/actions/group-participants";
import AlertMessage, { errorAlertItems } from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "./page.module.css";

async function saveState(_previousState, formData) {
  return saveGroupParticipantApplication(formData);
}

const EMPTY_FIELDS = {
  applicantName: "", applicantAddress: "", applicantPhone: "",
  emergencyContactName: "", emergencyContactAddress: "", emergencyContactPhone: "",
  notes: "", guardianConsentRequired: "",
};

export function groupParticipantFormFields(fields = {}) {
  return {
    ...EMPTY_FIELDS,
    applicantName: fields.applicantName ?? fields.user_name ?? "",
    applicantAddress: fields.applicantAddress ?? fields.user_address ?? "",
    applicantPhone: fields.applicantPhone ?? fields.user_phone ?? "",
    emergencyContactName: fields.emergencyContactName ?? fields.emergency_name ?? "",
    emergencyContactAddress: fields.emergencyContactAddress ?? fields.emergency_address ?? "",
    emergencyContactPhone: fields.emergencyContactPhone ?? fields.emergency_phone ?? "",
    notes: fields.notes ?? fields.special_notes ?? "",
    guardianConsentRequired: fields.guardianConsentRequired
      ?? (typeof fields.requires_guardian_consent === "boolean" ? String(fields.requires_guardian_consent) : ""),
  };
}

export default function GroupParticipantForm({ applicationId, updatedAt, initialFields }) {
  const normalized = groupParticipantFormFields(initialFields);
  const [state, formAction, pending] = useActionState(saveState, { error: null, fields: normalized, fieldErrors: {} });
  const summaryRef = useRef(null);
  const fields = groupParticipantFormFields(state?.fields ?? normalized);

  useEffect(() => {
    if (!state?.error) return;
    const firstName = Object.keys(state.fieldErrors ?? {})[0];
    const target = firstName ? document.getElementById(firstName) : null;
    (target ?? summaryRef.current)?.focus();
  }, [state]);

  return <form className={styles.form} action={formAction} noValidate>
    <input type="hidden" name="applicationId" value={applicationId} />
    <input type="hidden" name="updatedAt" value={updatedAt} />
    {state?.error && <div ref={summaryRef} tabIndex={-1} className={styles.focusTarget}>
      <AlertMessage tone="error" title="入力内容を保存できませんでした" items={errorAlertItems(state.fieldErrors)}>
        <p>{errorMessage(state.error)}</p>
      </AlertMessage>
    </div>}

    <fieldset className={styles.group}>
      <legend className={styles.groupTitle}>参加者本人の情報</legend>
      <p className={styles.groupDescription}>ここで入力した個人情報は、団体の他の参加者には表示されません。</p>
      <div className={styles.fields}>
        <FormField id="applicantName" name="applicantName" label="氏名" required maxLength={100} autoComplete="name" defaultValue={fields.applicantName} error={state?.fieldErrors?.applicantName} />
        <FormField id="applicantAddress" name="applicantAddress" label="住所" required maxLength={500} autoComplete="street-address" defaultValue={fields.applicantAddress} error={state?.fieldErrors?.applicantAddress} />
        <FormField id="applicantPhone" name="applicantPhone" label="電話番号" type="tel" required maxLength={20} autoComplete="tel" inputMode="tel" hint="数字、ハイフン、丸括弧を使用できます。" defaultValue={fields.applicantPhone} error={state?.fieldErrors?.applicantPhone} />
      </div>
    </fieldset>

    <fieldset className={styles.group}>
      <legend className={styles.groupTitle}>緊急連絡先</legend>
      <div className={styles.fields}>
        <FormField id="emergencyContactName" name="emergencyContactName" label="緊急連絡先の氏名" required maxLength={100} defaultValue={fields.emergencyContactName} error={state?.fieldErrors?.emergencyContactName} />
        <FormField id="emergencyContactAddress" name="emergencyContactAddress" label="緊急連絡先の住所" required maxLength={500} defaultValue={fields.emergencyContactAddress} error={state?.fieldErrors?.emergencyContactAddress} />
        <FormField id="emergencyContactPhone" name="emergencyContactPhone" label="緊急連絡先の電話番号" type="tel" required maxLength={20} inputMode="tel" hint="数字、ハイフン、丸括弧を使用できます。" defaultValue={fields.emergencyContactPhone} error={state?.fieldErrors?.emergencyContactPhone} />
      </div>
    </fieldset>

    <fieldset className={styles.group}>
      <legend className={styles.groupTitle}>補足情報</legend>
      <div className={styles.fields}>
        <FormField as="textarea" id="notes" name="notes" label="特記事項" rows={4} maxLength={2000} defaultValue={fields.notes} error={state?.fieldErrors?.notes} />
        <FormField as="radio" id="guardianConsentRequired" name="guardianConsentRequired" label="未成年者、または18歳の高校生に該当しますか" required hint="該当する場合は、下書き保存後に保護者同意書を添付してください。" options={[{ value: "true", label: "該当する" }, { value: "false", label: "該当しない" }]} defaultValue={fields.guardianConsentRequired} error={state?.fieldErrors?.guardianConsentRequired} />
      </div>
    </fieldset>

    <div className={styles.actions}>
      <SubmitButton name="intent" value="save" variant="secondary" pending={pending} pendingLabel="保存中…" fullWidthOnMobile>下書き保存</SubmitButton>
      <SubmitButton name="intent" value="confirm" pending={pending} pendingLabel="保存中…" fullWidthOnMobile>確認へ進む</SubmitButton>
    </div>
    <p className={styles.actionNote}>自動保存はされません。入力途中の場合は下書きを保存してください。</p>
  </form>;
}
