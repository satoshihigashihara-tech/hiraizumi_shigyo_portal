"use client";

import { useActionState } from "react";
import { createStaffCampState } from "@/app/actions/staff-camps";
import AlertMessage from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "./camps.module.css";

const INITIAL_STATE = { error: null, fields: {} };

export default function NewCampForm() {
  const [state, action, pending] = useActionState(createStaffCampState, INITIAL_STATE);
  const fields = state?.fields ?? {};
  return (
    <form className={styles.form} action={action}>
      {state?.error && <AlertMessage tone="error" title="キャンプを作成できませんでした"><p>{errorMessage(state.error)}</p></AlertMessage>}
      <FormField id="campName" name="campName" label="キャンプ名" required maxLength={120} defaultValue={fields.campName} />
      <div className={styles.twoColumns}>
        <FormField id="startDate" name="startDate" label="利用開始日" type="date" required defaultValue={fields.startDate} />
        <FormField id="endDate" name="endDate" label="利用終了日" type="date" required defaultValue={fields.endDate} />
      </div>
      <FormField id="applicationDeadline" name="applicationDeadline" label="申請期限" type="datetime-local" required defaultValue={fields.applicationDeadline} hint="利用開始日より前の日時を指定します。" />
      <SubmitButton pending={pending} pendingLabel="作成中…" fullWidthOnMobile>キャンプを作成する</SubmitButton>
    </form>
  );
}
