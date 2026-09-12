"use client";

import { useActionState } from "react";
import AlertMessage, { errorAlertItems } from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import { disableUserAccountState } from "@/app/actions/staff-accounts";
import { checkInApplicationState, checkOutApplicationState,
  saveApplicationStaffNoteState, updateApplicationPaymentState } from "@/app/actions/staff-application-operations";
import styles from "./page.module.css";

function ErrorText({ state }) {
  return state?.error ? <p className={styles.formError} role="alert">{errorMessage(state.error)}</p> : null;
}

export function PaymentForm({ applicationId, updatedAt, charge }) {
  const [state, action, pending] = useActionState(updateApplicationPaymentState, null);
  return <form className={styles.operationForm} action={action}>
    <input type="hidden" name="applicationId" value={applicationId} />
    <input type="hidden" name="updatedAt" value={updatedAt} />
    <ErrorText state={state} />
    <label>納付状態<select name="paymentStatus" defaultValue={state?.fields?.paymentStatus ?? charge.payment_status}>
      <option value="unpaid">未納</option><option value="paid">納付済み</option>
    </select></label>
    <label>納付期限<input name="paymentDueDate" type="date" defaultValue={state?.fields?.paymentDueDate ?? charge.payment_due_date ?? ""} /></label>
    <label>変更理由<textarea name="reason" rows="3" maxLength="2000" defaultValue={state?.fields?.reason ?? ""} /></label>
    <SubmitButton pending={pending} pendingLabel="納付情報を保存中…">納付情報を保存</SubmitButton>
  </form>;
}

export function StayOperationForm({ applicationId, updatedAt, operation }) {
  const serverAction = operation === "check_in" ? checkInApplicationState : checkOutApplicationState;
  const [state, action, pending] = useActionState(serverAction, null);
  const label = operation === "check_in" ? "入居を記録" : "退去を記録";
  return <form className={styles.operationForm} action={action}>
    <input type="hidden" name="applicationId" value={applicationId} />
    <input type="hidden" name="updatedAt" value={updatedAt} />
    <ErrorText state={state} />
    <p>現在時刻で{label}します。日時は手入力できません。</p>
    <SubmitButton pending={pending} pendingLabel="記録中…">{label}</SubmitButton>
  </form>;
}

export function NoteForm({ applicationId, updatedAt }) {
  const [state, action, pending] = useActionState(saveApplicationStaffNoteState, null);
  return <form className={styles.operationForm} action={action}>
    <input type="hidden" name="applicationId" value={applicationId} />
    <input type="hidden" name="updatedAt" value={updatedAt} />
    <input type="hidden" name="noteId" value="" />
    <ErrorText state={state} />
    <label>職員メモ<textarea name="body" rows="4" maxLength="2000" required defaultValue={state?.fields?.body ?? ""} /></label>
    <SubmitButton pending={pending} pendingLabel="メモを保存中…">職員メモを追加</SubmitButton>
  </form>;
}

export function AccountDisableForm({ applicationId, applicantName }) {
  const [state, action, pending] = useActionState(disableUserAccountState, null);
  return <form className={styles.operationForm} action={action}>
    <input type="hidden" name="applicationId" value={applicationId} />
    {state?.error && <AlertMessage
      tone="error"
      title="アカウントを停止できませんでした"
      items={errorAlertItems(state.fieldErrors)}
    ><p>{errorMessage(state.error)}</p></AlertMessage>}
    <p><strong>{applicantName || "この利用者"}</strong>から停止の依頼を受けたことを確認してから操作してください。</p>
    <p>停止後、この利用者は保護された画面へ入れなくなります。申請記録は管理記録として残ります。</p>
    <FormField
      id="reason"
      name="reason"
      label="停止理由（職員記録）"
      as="textarea"
      rows={3}
      maxLength={2000}
      required
      defaultValue={state?.fields?.reason ?? ""}
      error={state?.fieldErrors?.reason}
      hint="本人の画面には表示されません。"
    />
    <FormField
      id="confirmed"
      name="confirmed"
      as="checkbox"
      required
      label="本人からの停止依頼と対象者を確認しました"
      defaultChecked={state?.fields?.confirmed === "true"}
      error={state?.fieldErrors?.confirmed}
    />
    <SubmitButton variant="danger" pending={pending} pendingLabel="停止中…">
      この利用者のアカウントを停止する
    </SubmitButton>
  </form>;
}
