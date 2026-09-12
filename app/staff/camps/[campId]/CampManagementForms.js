"use client";

import { useActionState, useEffect, useRef } from "react";
import { deleteStaffCampState, updateStaffCampState } from "@/app/actions/staff-camps";
import AlertMessage, { errorAlertItems } from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import LinkButton from "@/app/components/LinkButton";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import { formatPeriod } from "@/app/components/format";
import styles from "../camps.module.css";

const INITIAL = { error: null, fields: {}, fieldErrors: {}, conflicts: [] };

function ErrorBlock({ state, title, focusRef, conflictId, hrefs = {} }) {
  if (!state?.error) return null;
  const items = errorAlertItems(state.fieldErrors).map((item) => ({ ...item, href: hrefs[item.href.slice(1)] ?? item.href }));
  return <div ref={focusRef} tabIndex={-1} className={styles.errorFocus}>
    <AlertMessage tone="error" title={title} items={items}><p>{errorMessage(state.error)}</p></AlertMessage>
    {state.conflicts?.length > 0 && <section className={styles.conflicts} aria-labelledby={conflictId}>
      <h3 id={conflictId}>影響する申請・日程</h3><ul>{state.conflicts.map((item) => {
        const href = item.type === "blocked" ? `/staff/calendar/blocked-periods/${item.id}/edit`
          : item.type === "group" ? `/staff/community/groups/${item.id}`
            : item.type === "camp" ? `/staff/camps/${item.id}`
              : item.campId ? `/staff/camps/${item.campId}/applications/${item.id}` : `/staff/community/applications/${item.id}`;
        return <li key={`${item.type}-${item.id}`}><strong>{item.name || item.receptionNumber || "登録済みの予定"}</strong>
          <span>{formatPeriod(item.startDate, item.endDate)}</span><LinkButton href={href}>詳細を確認する</LinkButton></li>;
      })}</ul>
    </section>}
  </div>;
}

export default function CampManagementForms({ camp, deadlineValue }) {
  const [saveState, saveAction, savePending] = useActionState(updateStaffCampState, INITIAL);
  const [deleteState, deleteAction, deletePending] = useActionState(deleteStaffCampState, INITIAL);
  const saveRef = useRef(null); const deleteRef = useRef(null);
  useEffect(() => { if (saveState?.error) saveRef.current?.focus(); }, [saveState]);
  useEffect(() => { if (deleteState?.error) deleteRef.current?.focus(); }, [deleteState]);
  const fields = saveState?.fields ?? {};
  return <div className={styles.formStack}>
    <form className={styles.form} action={saveAction}>
      <ErrorBlock state={saveState} title="キャンプを保存できませんでした" focusRef={saveRef} conflictId="save-camp-conflicts" />
      <input type="hidden" name="campId" value={camp.id} /><input type="hidden" name="updatedAt" value={camp.updated_at} />
      <FormField id="campName" name="campName" label="キャンプ名" required maxLength={120} defaultValue={fields.campName ?? camp.name} />
      <div className={styles.twoColumns}><FormField id="startDate" name="startDate" label="利用開始日" type="date" required defaultValue={fields.startDate ?? camp.start_date} />
        <FormField id="endDate" name="endDate" label="利用終了日" type="date" required defaultValue={fields.endDate ?? camp.end_date} /></div>
      <FormField id="applicationDeadline" name="applicationDeadline" label="申請期限" type="datetime-local" required defaultValue={fields.applicationDeadline ?? deadlineValue} hint="利用開始日より前の日時を指定します。" />
      <FormField id="reason" name="reason" label="変更理由" as="textarea" rows={3} maxLength={2000} defaultValue={fields.reason} hint="内容を変更する場合に入力します。同じ内容の保存では省略できます。" />
      <SubmitButton pending={savePending} pendingLabel="保存中…" fullWidthOnMobile>変更を保存する</SubmitButton>
    </form>
    <section className={styles.dangerZone} aria-labelledby="delete-camp-title"><h2 id="delete-camp-title">キャンプを削除</h2>
      <p>削除すると対象者から見えなくなり、確保していた日程枠を解放します。既存の有効な申請がある場合は削除できません。</p>
      <form className={styles.form} action={deleteAction}>
        <ErrorBlock state={deleteState} title="キャンプを削除できませんでした" focusRef={deleteRef} conflictId="delete-camp-conflicts" hrefs={{ reason: "#delete-reason" }} />
        <input type="hidden" name="campId" value={camp.id} /><input type="hidden" name="updatedAt" value={camp.updated_at} />
        <FormField id="delete-reason" name="reason" label="削除理由" as="textarea" rows={3} maxLength={2000} required defaultValue={deleteState?.fields?.reason} />
        <FormField id="confirmed" name="confirmed" as="checkbox" required label="このキャンプを削除し、日程枠を解放することを確認しました" error={deleteState?.fieldErrors?.confirmed} />
        <SubmitButton pending={deletePending} pendingLabel="削除中…" variant="danger" fullWidthOnMobile>キャンプを削除する</SubmitButton>
      </form>
    </section>
  </div>;
}
