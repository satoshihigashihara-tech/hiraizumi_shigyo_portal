"use client";

import { useActionState } from "react";
import { createCampRosterEligibleUserState, disableCampEligibleUserState, updateCampEligibleUserState, updateCampRosterEligibleUserState } from "@/app/actions/staff-camps";
import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "../../camps.module.css";

const INITIAL = { error: null, fields: {}, fieldErrors: {} };

function RosterRegistration({ campId }) {
  const [state, action, pending] = useActionState(createCampRosterEligibleUserState, INITIAL);
  return <form className={styles.form} action={action}>
    {state?.error && <AlertMessage tone="error" title="対象者を登録できませんでした"><p>{errorMessage(state.error)}</p></AlertMessage>}
    {state?.success === "create" && <AlertMessage tone="success" title="対象者を登録しました" />}
    <input type="hidden" name="campId" value={campId} />
    <FormField id="managementName" name="managementName" label="管理用氏名" required maxLength={200} defaultValue={state?.fields?.managementName} error={state?.fieldErrors?.managementName} hint="この氏名は対象者名簿の管理用です。プロフィールや申請書の氏名は変更しません。" />
    <FormField id="rosterEmail" name="email" label="メールアドレス" type="email" required autoComplete="email" defaultValue={state?.fields?.email} error={state?.fieldErrors?.email} hint="同じキャンプで既に登録されているメールアドレスは登録できません。" />
    <SubmitButton pending={pending} pendingLabel="登録中…" fullWidthOnMobile>対象者を登録する</SubmitButton>
  </form>;
}

function LegacyUserRow({ campId, user }) {
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

function RosterUserRow({ campId, user }) {
  const [state, action, pending] = useActionState(updateCampRosterEligibleUserState, INITIAL);
  const editable = !user.disabled_at && user.participation_status === "participating";
  const stateLabel = user.disabled_at ? "資格無効" : user.participation_status === "released" ? "今回の参加終了" : "参加中";
  return <li className={styles.eligibleCard}>
    <div><strong>{user.management_name ?? "管理用氏名未設定"}</strong><span className={styles.stateText}>{stateLabel}</span></div>
    <p className={styles.rosterEmail}>{user.email_normalized}</p>
    {user.is_linked && <p>申請アカウントと結合済みです。メールを変更しても結合先アカウントは変更されません。</p>}
    {user.has_application && <p>この対象者には申請記録があります。</p>}
    {!editable ? <p>この対象者の復活・再参加は、この画面では行えません。</p> : <form className={styles.compactForm} action={action}>
      {state?.error && <AlertMessage tone="error" title="対象者を変更できませんでした"><p>{errorMessage(state.error)}</p></AlertMessage>}
      {state?.success === "update" && <AlertMessage tone="success" title="対象者を変更しました" />}
      <input type="hidden" name="campId" value={campId} /><input type="hidden" name="eligibleUserId" value={user.id} /><input type="hidden" name="updatedAt" value={user.updated_at} />
      <FormField id={`management-name-${user.id}`} name="managementName" label="管理用氏名" required maxLength={200} defaultValue={state?.fields?.managementName ?? user.management_name ?? ""} error={state?.fieldErrors?.managementName} />
      <FormField id={`roster-email-${user.id}`} name="email" label="メールアドレス" type="email" required defaultValue={state?.fields?.email ?? user.email_normalized} error={state?.fieldErrors?.email} />
      {user.is_linked && <FormField id={`reason-${user.id}`} name="reason" label="メールアドレス変更理由" as="textarea" rows={2} maxLength={2000} defaultValue={state?.fields?.reason} error={state?.fieldErrors?.reason} hint="結合済み対象者のメールアドレスを変更する場合に必須です。氏名のみの変更では不要です。" />}
      <SubmitButton pending={pending} pendingLabel="変更中…">対象者を変更する</SubmitButton>
    </form>}
  </li>;
}

export default function EligibleUserForms({ campId, users, mode }) {
  if (mode === "roster") return <>
    <RosterRegistration campId={campId} />
    {users.length === 0 ? <EmptyState title="対象者はまだ登録されていません" description="上のフォームから氏名とメールアドレスを登録してください。" /> : <ul className={styles.eligibleList}>{users.map((user) => <RosterUserRow key={user.id} campId={campId} user={user} />)}</ul>}
  </>;
  return <ul className={styles.eligibleList}>{users.map((user) => <LegacyUserRow key={user.id} campId={campId} user={user} />)}</ul>;
}
