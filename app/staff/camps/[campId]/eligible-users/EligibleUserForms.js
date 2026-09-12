"use client";

import { useActionState } from "react";
import { disableCampEligibleUserState, updateCampEligibleUserState } from "@/app/actions/staff-camps";
import AlertMessage from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "../../camps.module.css";

const INITIAL = { error: null, fields: {}, fieldErrors: {} };

function UserRow({ campId, user }) {
  const [editState, editAction, editPending] = useActionState(updateCampEligibleUserState, INITIAL);
  const [disableState, disableAction, disablePending] = useActionState(disableCampEligibleUserState, INITIAL);
  return <li className={styles.eligibleCard}>
    <div><strong>{user.email_normalized}</strong><span className={styles.stateText}>{user.disabled_at ? "無効" : "有効"}</span></div>
    {user.disabled_at ? <p>再び対象にする場合は、上の登録欄へ同じメールアドレスを入力してください。</p> : <>
      <form className={styles.compactForm} action={editAction}>
        {editState?.error && <AlertMessage tone="error" title="メールアドレスを変更できませんでした"><p>{errorMessage(editState.error)}</p></AlertMessage>}
        <input type="hidden" name="campId" value={campId} /><input type="hidden" name="eligibleUserId" value={user.id} /><input type="hidden" name="updatedAt" value={user.updated_at} />
        <FormField id={`email-${user.id}`} name="email" label="変更後のメールアドレス" type="email" required defaultValue={editState?.fields?.email ?? user.email_normalized} error={editState?.fieldErrors?.email} />
        <FormField id={`reason-${user.id}`} name="reason" label="変更理由" as="textarea" rows={2} maxLength={2000} required defaultValue={editState?.fields?.reason} error={editState?.fieldErrors?.reason} />
        <SubmitButton pending={editPending} pendingLabel="変更中…">メールアドレスを変更する</SubmitButton>
      </form>
      <form className={styles.compactForm} action={disableAction}>
        {disableState?.error && <AlertMessage tone="error" title="対象者を無効にできませんでした"><p>{errorMessage(disableState.error)}</p></AlertMessage>}
        <input type="hidden" name="campId" value={campId} /><input type="hidden" name="eligibleUserId" value={user.id} /><input type="hidden" name="updatedAt" value={user.updated_at} />
        <FormField id={`disable-reason-${user.id}`} name="reason" label="無効化理由" as="textarea" rows={2} maxLength={2000} required defaultValue={disableState?.fields?.reason} error={disableState?.fieldErrors?.reason} />
        <FormField id={`confirmed-${user.id}`} name="confirmed" as="checkbox" required label="この対象者を無効にすることを確認しました" error={disableState?.fieldErrors?.confirmed} />
        <SubmitButton pending={disablePending} pendingLabel="無効化中…" variant="danger">対象者を無効にする</SubmitButton>
      </form>
    </>}
  </li>;
}

export default function EligibleUserForms({ campId, users }) {
  return <ul className={styles.eligibleList}>{users.map((user) => <UserRow key={user.id} campId={campId} user={user} />)}</ul>;
}
