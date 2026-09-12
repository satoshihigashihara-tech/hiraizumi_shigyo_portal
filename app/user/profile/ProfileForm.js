"use client";

import { useActionState } from "react";
import { saveProfileState } from "@/app/actions/profile";
import AlertMessage from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "./page.module.css";

export default function ProfileForm({ mode, profile }) {
  const [state, action, pending] = useActionState(saveProfileState, {
    error: null,
    fieldErrors: {},
    fields: profile,
  });
  const fields = state?.fields ?? profile;
  const errors = state?.fieldErrors ?? {};

  return (
    <form className={styles.form} action={action}>
      {mode && <input type="hidden" name="mode" value={mode} />}
      {state?.error && (
        <AlertMessage tone="error" title="プロフィールを保存できませんでした">
          <p>{errorMessage(state.error)}</p>
        </AlertMessage>
      )}

      <fieldset className={styles.group}>
        <legend className={styles.legend}>本人情報</legend>
        <FormField id="fullName" name="fullName" label="氏名" defaultValue={fields.fullName} error={errors.fullName} autoComplete="name" maxLength={100} />
        <FormField id="address" name="address" label="住所" as="textarea" defaultValue={fields.address} error={errors.address} autoComplete="street-address" maxLength={500} rows={3} />
        <FormField id="phone" name="phone" label="電話番号" type="tel" defaultValue={fields.phone} error={errors.phone} autoComplete="tel" inputMode="tel" maxLength={20} hint="数字、ハイフン、括弧、プラス記号を使用できます。" />
      </fieldset>

      <fieldset className={styles.group}>
        <legend className={styles.legend}>緊急連絡先</legend>
        <p className={styles.note}>緊急時に連絡できる方の情報を入力してください。</p>
        <FormField id="emergencyName" name="emergencyName" label="氏名" defaultValue={fields.emergencyName} error={errors.emergencyName} maxLength={100} />
        <FormField id="emergencyAddress" name="emergencyAddress" label="住所" as="textarea" defaultValue={fields.emergencyAddress} error={errors.emergencyAddress} maxLength={500} rows={3} />
        <FormField id="emergencyPhone" name="emergencyPhone" label="電話番号" type="tel" defaultValue={fields.emergencyPhone} error={errors.emergencyPhone} inputMode="tel" maxLength={20} hint="数字、ハイフン、括弧、プラス記号を使用できます。" />
      </fieldset>

      <p className={styles.note}>空欄の項目は未登録として保存されます。申請を提出する際は、必要項目を申請画面で確認してください。</p>
      <SubmitButton pending={pending} pendingLabel="保存中…" fullWidthOnMobile>プロフィールを保存する</SubmitButton>
    </form>
  );
}
