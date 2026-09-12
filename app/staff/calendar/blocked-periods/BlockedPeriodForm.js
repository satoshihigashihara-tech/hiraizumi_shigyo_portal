"use client";

import { useActionState, useEffect, useRef } from "react";
import {
  createStaffBlockedPeriodState,
  deleteStaffBlockedPeriodState,
  updateStaffBlockedPeriodState,
} from "@/app/actions/staff-calendar";
import AlertMessage, { errorAlertItems } from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import LinkButton from "@/app/components/LinkButton";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import { formatPeriod } from "@/app/components/format";
import styles from "../calendar.module.css";

const INITIAL_STATE = { error: null, fields: {}, fieldErrors: {}, conflicts: [] };

function ConflictList({ conflicts }) {
  if (!Array.isArray(conflicts) || conflicts.length === 0) return null;
  return <section className={styles.conflicts} aria-labelledby="conflict-heading"><h3 id="conflict-heading">重なっている日程</h3>
    <ul>{conflicts.map((conflict) => {
      const href = conflict.type === "camp" ? `/staff/camps/${conflict.campId || conflict.id}`
        : conflict.type === "blocked" ? `/staff/calendar/blocked-periods/${conflict.id}/edit`
          : conflict.type === "group" ? `/staff/community/groups/${conflict.id}`
            : conflict.campId ? `/staff/camps/${conflict.campId}/applications/${conflict.id}` : `/staff/community/applications/${conflict.id}`;
      return <li key={`${conflict.type}-${conflict.id}`}><strong>{conflict.name || conflict.receptionNumber || "登録済みの予定"}</strong>
        <span>{formatPeriod(conflict.startDate, conflict.endDate)}</span><LinkButton href={href}>詳細を確認する</LinkButton></li>;
    })}</ul>
  </section>;
}

function FormError({ state, title, errorRef, itemHrefByField = {} }) {
  if (!state?.error) return null;
  const items = errorAlertItems(state.fieldErrors).map((item) => ({
    ...item,
    href: itemHrefByField[item.href.slice(1)] ?? item.href,
  }));
  return <div ref={errorRef} tabIndex={-1} className={styles.errorFocus}>
    <AlertMessage tone="error" title={title} items={items}><p>{errorMessage(state.error)}</p></AlertMessage>
    <ConflictList conflicts={state.conflicts} />
  </div>;
}

export default function BlockedPeriodForm({ mode, period = null }) {
  const editing = mode === "edit";
  const saveAction = editing ? updateStaffBlockedPeriodState : createStaffBlockedPeriodState;
  const [saveState, saveFormAction, savePending] = useActionState(saveAction, INITIAL_STATE);
  const [deleteState, deleteFormAction, deletePending] = useActionState(deleteStaffBlockedPeriodState, INITIAL_STATE);
  const saveErrorRef = useRef(null);
  const deleteErrorRef = useRef(null);
  useEffect(() => { if (saveState?.error) saveErrorRef.current?.focus(); }, [saveState]);
  useEffect(() => { if (deleteState?.error) deleteErrorRef.current?.focus(); }, [deleteState]);
  const fields = saveState?.fields ?? {};
  const startDate = fields.startDate ?? period?.start_date ?? "";
  const endDate = fields.endDate ?? period?.end_date ?? "";
  const internalReason = fields.internalReason ?? period?.internal_reason ?? "";

  return <div className={styles.formStack}>
    <form className={styles.form} action={saveFormAction}>
      <FormError state={saveState} title="利用停止期間を保存できませんでした" errorRef={saveErrorRef} />
      {editing && <><input type="hidden" name="blockedPeriodId" value={period.id} /><input type="hidden" name="updatedAt" value={period.updated_at} /></>}
      <div className={styles.twoColumns}>
        <FormField id="startDate" name="startDate" label="開始日" type="date" required defaultValue={startDate} error={saveState?.fieldErrors?.startDate} />
        <FormField id="endDate" name="endDate" label="終了日" type="date" required defaultValue={endDate} error={saveState?.fieldErrors?.endDate} />
      </div>
      <FormField id="internalReason" name="internalReason" label="内部理由" as="textarea" rows={4} maxLength={2000} required defaultValue={internalReason} error={saveState?.fieldErrors?.internalReason} hint="清掃、修繕、町行事など、職員だけが確認する理由を入力します。" />
      {editing && <FormField id="reason" name="reason" label="変更理由" as="textarea" rows={3} maxLength={2000} defaultValue={fields.reason} error={saveState?.fieldErrors?.reason} hint="日付または内部理由を変更する場合に入力します。同じ内容の保存では省略できます。" />}
      <SubmitButton pending={savePending} pendingLabel="保存中…" fullWidthOnMobile>{editing ? "変更を保存する" : "利用停止期間を作る"}</SubmitButton>
    </form>
    {editing && <section className={styles.dangerZone} aria-labelledby="delete-period-heading">
      <h2 id="delete-period-heading">利用停止期間を削除</h2>
      <p>削除すると、この期間の日程枠が解放されます。元に戻す操作はありません。</p>
      <form className={styles.form} action={deleteFormAction}>
        <FormError state={deleteState} title="利用停止期間を削除できませんでした" errorRef={deleteErrorRef} itemHrefByField={{ reason: "#delete-reason" }} />
        <input type="hidden" name="blockedPeriodId" value={period.id} />
        <input type="hidden" name="updatedAt" value={period.updated_at} />
        <FormField id="delete-reason" name="reason" label="削除理由" as="textarea" rows={3} maxLength={2000} required defaultValue={deleteState?.fields?.reason} error={deleteState?.fieldErrors?.reason} />
        <FormField id="confirmed" name="confirmed" as="checkbox" label="この利用停止期間を削除し、日程枠を解放することを確認しました" required error={deleteState?.fieldErrors?.confirmed} />
        <SubmitButton pending={deletePending} pendingLabel="削除中…" variant="danger" fullWidthOnMobile>利用停止期間を削除する</SubmitButton>
      </form>
    </section>}
  </div>;
}
