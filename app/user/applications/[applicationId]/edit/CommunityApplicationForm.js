"use client";

import { useActionState, useEffect, useRef } from "react";
import { createCommunityApplicationDraft, saveCommunityApplicationDraft } from "@/app/actions/community-applications";
import AlertMessage, { errorAlertItems } from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "./page.module.css";

async function createState(_previousState, formData) {
  return createCommunityApplicationDraft(formData);
}

async function saveState(_previousState, formData) {
  return saveCommunityApplicationDraft(formData);
}

const EMPTY_FIELDS = {
  applicantName: "", applicantAddress: "", applicantPhone: "",
  emergencyContactName: "", emergencyContactAddress: "", emergencyContactPhone: "",
  usagePurpose: "", localActivity: "", notes: "", usagePlace: "common_and_second_floor",
  startDate: "", endDate: "", guardianConsentRequired: "",
};

export function communityFormFields(fields = {}) {
  return {
    ...EMPTY_FIELDS,
    applicantName: fields.applicantName ?? fields.user_name ?? "",
    applicantAddress: fields.applicantAddress ?? fields.user_address ?? "",
    applicantPhone: fields.applicantPhone ?? fields.user_phone ?? "",
    emergencyContactName: fields.emergencyContactName ?? fields.emergency_name ?? "",
    emergencyContactAddress: fields.emergencyContactAddress ?? fields.emergency_address ?? "",
    emergencyContactPhone: fields.emergencyContactPhone ?? fields.emergency_phone ?? "",
    usagePurpose: fields.usagePurpose ?? fields.purpose ?? "",
    localActivity: fields.localActivity ?? fields.local_activity ?? "",
    notes: fields.notes ?? fields.special_notes ?? "",
    usagePlace: fields.usagePlace ?? fields.usage_place ?? "common_and_second_floor",
    startDate: fields.startDate ?? fields.start_date ?? "",
    endDate: fields.endDate ?? fields.end_date ?? "",
    guardianConsentRequired: fields.guardianConsentRequired ?? (typeof fields.requires_guardian_consent === "boolean" ? String(fields.requires_guardian_consent) : ""),
  };
}

export default function CommunityApplicationForm({ applicationId, initialFields, updatedAt, mode = "edit" }) {
  const action = mode === "create" ? createState : saveState;
  const normalized = communityFormFields(initialFields);
  const [state, formAction, pending] = useActionState(action, { error: null, fields: normalized, fieldErrors: {} });
  const summaryRef = useRef(null);
  const fields = communityFormFields(state?.fields ?? normalized);

  useEffect(() => {
    if (!state?.error) return;
    const firstName = Object.keys(state.fieldErrors ?? {})[0];
    const target = firstName ? document.getElementById(firstName) : null;
    (target ?? summaryRef.current)?.focus();
  }, [state]);

  return <form className={styles.form} action={formAction} noValidate>
    <input type="hidden" name="applicationId" value={applicationId} />
    {updatedAt && <input type="hidden" name="updatedAt" value={updatedAt} />}
    {state?.error && <div ref={summaryRef} tabIndex={-1} className={styles.focusTarget}>
      <AlertMessage tone="error" title="入力内容を保存できませんでした" items={errorAlertItems(state.fieldErrors)}>
        <p>{errorMessage(state.error)}</p>
      </AlertMessage>
    </div>}

    <fieldset className={styles.group}>
      <legend className={styles.groupTitle}>利用期間</legend>
      <p className={styles.groupDescription}>開始日は申請日の14日後以降、終了日は60日後までです。利用期間は2日から15日まで指定できます。</p>
      <div className={styles.fields}>
        <FormField id="startDate" name="startDate" label="使用開始日" type="date" required defaultValue={fields.startDate} error={state?.fieldErrors?.startDate} />
        <FormField id="endDate" name="endDate" label="使用終了日" type="date" required defaultValue={fields.endDate} error={state?.fieldErrors?.endDate} />
      </div>
    </fieldset>

    <fieldset className={styles.group}>
      <legend className={styles.groupTitle}>申請者情報</legend>
      <p className={styles.groupDescription}>プロフィールの内容を初期表示しています。この申請時点の情報として保存します。</p>
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
      <legend className={styles.groupTitle}>利用内容</legend>
      <div className={styles.fields}>
        <FormField as="select" id="usagePlace" name="usagePlace" label="使用箇所" required options={[{ value: "common_and_second_floor", label: "共用部分及び2階個室" }]} defaultValue={fields.usagePlace} error={state?.fieldErrors?.usagePlace} />
        <FormField as="textarea" id="usagePurpose" name="usagePurpose" label="使用目的" required rows={4} maxLength={2000} defaultValue={fields.usagePurpose} error={state?.fieldErrors?.usagePurpose} />
        <FormField as="textarea" id="localActivity" name="localActivity" label="平泉町内で行う活動" required rows={5} maxLength={2000} hint="活動内容、場所、関係者などを具体的に入力してください。" defaultValue={fields.localActivity} error={state?.fieldErrors?.localActivity} />
        <FormField as="textarea" id="notes" name="notes" label="特記事項" rows={4} maxLength={2000} defaultValue={fields.notes} error={state?.fieldErrors?.notes} />
      </div>
    </fieldset>

    <fieldset className={styles.group}>
      <legend className={styles.groupTitle}>確認事項</legend>
      <FormField as="radio" id="guardianConsentRequired" name="guardianConsentRequired" label="未成年者、または18歳の高校生に該当しますか" required hint="該当する場合は、下書き作成後に保護者同意書を添付してください。" options={[{ value: "true", label: "該当する" }, { value: "false", label: "該当しない" }]} defaultValue={fields.guardianConsentRequired} error={state?.fieldErrors?.guardianConsentRequired} />
    </fieldset>

    <div className={styles.actions}>
      <SubmitButton name="intent" value="save" variant="secondary" pending={pending} pendingLabel="保存中…" fullWidthOnMobile>{mode === "create" ? "下書きを作成" : "下書き保存"}</SubmitButton>
      <SubmitButton name="intent" value="confirm" pending={pending} pendingLabel="保存中…" fullWidthOnMobile>確認へ進む</SubmitButton>
    </div>
    <p className={styles.actionNote}>自動保存はされません。入力途中の場合は下書きを保存してください。</p>
  </form>;
}
