"use client";

import { useActionState, useEffect, useRef, useState } from "react";
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
  const nextRowId = useRef(1);
  const [eligibleUsers, setEligibleUsers] = useState([{ id: 0, managementName: "", email: "" }]);

  useEffect(() => {
    if (!Array.isArray(fields.eligibleUsers) || fields.eligibleUsers.length === 0) return;
    setEligibleUsers(fields.eligibleUsers.map((eligibleUser) => ({
      id: nextRowId.current++,
      managementName: eligibleUser.managementName ?? "",
      email: eligibleUser.email ?? "",
    })));
  }, [fields.eligibleUsers]);

  function addEligibleUser() {
    setEligibleUsers((current) => current.length >= 15 ? current : [
      ...current,
      { id: nextRowId.current++, managementName: "", email: "" },
    ]);
  }

  function removeEligibleUser(id) {
    setEligibleUsers((current) => current.length === 1 ? current : current.filter((item) => item.id !== id));
  }

  return (
    <form className={styles.form} action={action}>
      {state?.error && <AlertMessage tone="error" title="キャンプを作成できませんでした"><p>{errorMessage(state.error)}</p></AlertMessage>}
      <FormField id="campName" name="campName" label="キャンプ名" required maxLength={120} defaultValue={fields.campName} />
      <div className={styles.twoColumns}>
        <FormField id="startDate" name="startDate" label="利用開始日" type="date" required defaultValue={fields.startDate} />
        <FormField id="endDate" name="endDate" label="利用終了日" type="date" required defaultValue={fields.endDate} />
      </div>
      <FormField id="applicationDeadline" name="applicationDeadline" label="申請期限" type="datetime-local" required defaultValue={fields.applicationDeadline} hint="利用開始日より前の日時を指定します。" />
      <fieldset className={styles.rosterFields}>
        <legend>対象者名簿</legend>
        <p className={styles.rosterHelp}>キャンプに参加できる方の氏名とメールアドレスをセットで入力してください。最大15人です。</p>
        <ol className={styles.rosterRows}>
          {eligibleUsers.map((eligibleUser, index) => (
            <li key={eligibleUser.id} className={styles.rosterRow}>
              <p className={styles.rosterRowTitle}>対象者 {index + 1}</p>
              <div className={styles.twoColumns}>
                <FormField id={`eligibleName-${eligibleUser.id}`} name="eligibleName" label="氏名" required maxLength={200}
                  defaultValue={eligibleUser.managementName} error={state?.fieldErrors?.[`eligibleName-${index}`]} autoComplete="name" />
                <FormField id={`eligibleEmail-${eligibleUser.id}`} name="eligibleEmail" label="メールアドレス" type="email" required maxLength={254}
                  defaultValue={eligibleUser.email} error={state?.fieldErrors?.[`eligibleEmail-${index}`]} autoComplete="email" />
              </div>
              <button className={styles.removeRosterButton} type="button" onClick={() => removeEligibleUser(eligibleUser.id)}
                disabled={eligibleUsers.length === 1}>この対象者を削除</button>
            </li>
          ))}
        </ol>
        <button className={styles.addRosterButton} type="button" onClick={addEligibleUser} disabled={eligibleUsers.length >= 15}>
          対象者を追加
        </button>
      </fieldset>
      <SubmitButton pending={pending} pendingLabel="作成中…" fullWidthOnMobile>キャンプを作成する</SubmitButton>
    </form>
  );
}
