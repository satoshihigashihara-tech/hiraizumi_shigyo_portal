"use client";

import { useActionState, useEffect, useRef } from "react";
import {
  createCommunityGroupDraft,
  saveCommunityGroupDraft,
} from "@/app/actions/community-groups";
import AlertMessage, { errorAlertItems } from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "../../groups.module.css";

async function createState(_previousState, formData) {
  return createCommunityGroupDraft(formData);
}

async function saveState(_previousState, formData) {
  return saveCommunityGroupDraft(formData);
}

const EMPTY = {
  groupName: "", representativeName: "", representativeAddress: "",
  representativePhone: "", startDate: "", endDate: "",
  usagePlace: "common_and_second_floor", purpose: "", localActivity: "",
  notes: "", plannedParticipants: "", representativeStays: "",
};

export function groupFormFields(fields = {}) {
  return {
    ...EMPTY,
    groupName: fields.groupName ?? fields.group_name ?? "",
    representativeName: fields.representativeName ?? fields.representative_name ?? "",
    representativeAddress: fields.representativeAddress ?? fields.representative_address ?? "",
    representativePhone: fields.representativePhone ?? fields.representative_phone ?? "",
    startDate: fields.startDate ?? fields.start_date ?? "",
    endDate: fields.endDate ?? fields.end_date ?? "",
    usagePlace: fields.usagePlace ?? fields.usage_place ?? "common_and_second_floor",
    purpose: fields.purpose ?? "",
    localActivity: fields.localActivity ?? fields.local_activity ?? "",
    notes: fields.notes ?? fields.special_notes ?? "",
    plannedParticipants: String(fields.plannedParticipants ?? fields.planned_participants ?? ""),
    representativeStays: fields.representativeStays
      ?? (typeof fields.representative_stays === "boolean" ? String(fields.representative_stays) : ""),
  };
}

export default function GroupForm({ groupId, initialFields, updatedAt, mode = "edit" }) {
  const normalized = groupFormFields(initialFields);
  const [state, action, pending] = useActionState(
    mode === "create" ? createState : saveState,
    { error: null, fields: normalized, fieldErrors: {} },
  );
  const summaryRef = useRef(null);
  const fields = groupFormFields(state?.fields ?? normalized);

  useEffect(() => {
    if (!state?.error) return;
    const first = Object.keys(state.fieldErrors ?? {})[0];
    (first ? document.getElementById(first) : summaryRef.current)?.focus();
  }, [state]);

  return (
    <form className={styles.form} action={action} noValidate>
      <input type="hidden" name="groupId" value={groupId} />
      {updatedAt && <input type="hidden" name="updatedAt" value={updatedAt} />}
      {state?.error && <div ref={summaryRef} tabIndex={-1} className={styles.focusTarget}>
        <AlertMessage tone="error" title="団体情報を保存できませんでした" items={errorAlertItems(state.fieldErrors)}>
          <p>{errorMessage(state.error)}</p>
        </AlertMessage>
      </div>}

      <fieldset className={styles.group}>
        <legend className={styles.groupTitle}>団体と代表者</legend>
        <p className={styles.groupDescription}>参加者には代表者の住所や電話番号を表示しません。</p>
        <div className={styles.fields}>
          <FormField id="groupName" name="groupName" label="団体名" required maxLength={120} defaultValue={fields.groupName} error={state?.fieldErrors?.groupName} />
          <FormField id="representativeName" name="representativeName" label="代表者氏名" required maxLength={100} autoComplete="name" defaultValue={fields.representativeName} error={state?.fieldErrors?.representativeName} />
          <FormField id="representativeAddress" name="representativeAddress" label="代表者住所" required maxLength={500} autoComplete="street-address" defaultValue={fields.representativeAddress} error={state?.fieldErrors?.representativeAddress} />
          <FormField id="representativePhone" name="representativePhone" label="代表者電話番号" type="tel" required maxLength={20} inputMode="tel" autoComplete="tel" defaultValue={fields.representativePhone} error={state?.fieldErrors?.representativePhone} />
        </div>
      </fieldset>

      <fieldset className={styles.group}>
        <legend className={styles.groupTitle}>利用期間と人数</legend>
        <p className={styles.groupDescription}>利用期間は2日から15日、予定人数は代表者を含め2人から15人です。</p>
        <div className={styles.fields}>
          <FormField id="startDate" name="startDate" label="使用開始日" type="date" required defaultValue={fields.startDate} error={state?.fieldErrors?.startDate} />
          <FormField id="endDate" name="endDate" label="使用終了日" type="date" required defaultValue={fields.endDate} error={state?.fieldErrors?.endDate} />
          <FormField id="plannedParticipants" name="plannedParticipants" label="予定人数" type="number" required inputMode="numeric" defaultValue={fields.plannedParticipants} error={state?.fieldErrors?.plannedParticipants} />
          <FormField as="radio" id="representativeStays" name="representativeStays" label="代表者本人も宿泊しますか" required options={[{ value: "true", label: "宿泊する" }, { value: "false", label: "宿泊しない" }]} defaultValue={fields.representativeStays} error={state?.fieldErrors?.representativeStays} />
        </div>
      </fieldset>

      <fieldset className={styles.group}>
        <legend className={styles.groupTitle}>利用内容</legend>
        <div className={styles.fields}>
          <FormField as="select" id="usagePlace" name="usagePlace" label="使用箇所" required options={[{ value: "common_and_second_floor", label: "共用部分及び2階個室" }]} defaultValue={fields.usagePlace} error={state?.fieldErrors?.usagePlace} />
          <FormField as="textarea" id="purpose" name="purpose" label="使用目的" required rows={4} maxLength={2000} defaultValue={fields.purpose} error={state?.fieldErrors?.purpose} />
          <FormField as="textarea" id="localActivity" name="localActivity" label="平泉町内で行う活動" required rows={5} maxLength={2000} defaultValue={fields.localActivity} error={state?.fieldErrors?.localActivity} />
          <FormField as="textarea" id="notes" name="notes" label="特記事項" rows={4} maxLength={2000} defaultValue={fields.notes} error={state?.fieldErrors?.notes} />
        </div>
      </fieldset>

      <div className={styles.actions}>
        <SubmitButton name="intent" value="save" variant="secondary" pending={pending} pendingLabel="保存中…" fullWidthOnMobile>{mode === "create" ? "下書きを作成" : "下書き保存"}</SubmitButton>
        <SubmitButton name="intent" value="confirm" pending={pending} pendingLabel="保存中…" fullWidthOnMobile>確認へ進む</SubmitButton>
      </div>
      <p className={styles.note}>自動保存はされません。ボタンを押したときだけ保存します。</p>
    </form>
  );
}
