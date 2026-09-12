"use client";

import { useActionState, useState } from "react";
import { startCommunityGroupApplication } from "@/app/actions/community-groups";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "../../groups.module.css";

async function submitState(_previousState, formData) {
  return startCommunityGroupApplication(formData);
}

export default function SubmitGroup({ group }) {
  const [confirmed, setConfirmed] = useState(false);
  const [submissionKey] = useState(() => crypto.randomUUID());
  const [state, action, pending] = useActionState(submitState, { error: null });
  return (
    <form className={styles.submissionPanel} action={action}>
      <input type="hidden" name="groupId" value={group.id} />
      <input type="hidden" name="updatedAt" value={group.updated_at} />
      <input type="hidden" name="submissionKey" value={submissionKey} />
      {state?.error && <AlertMessage tone="error" title="団体申請を開始できませんでした"><p>{errorMessage(state.error)}</p></AlertMessage>}
      <label><input type="checkbox" name="confirmed" value="true" checked={confirmed} onChange={(event) => setConfirmed(event.target.checked)} required /> 入力内容を確認し、団体申請を開始します</label>
      <p className={styles.note}>申請開始後に参加者を招待します。この時点では利用は確定しません。</p>
      <div className={styles.actions}>
        <LinkButton href={`/user/groups/${group.id}/edit`} variant="secondary" fullWidthOnMobile>入力へ戻る</LinkButton>
        <SubmitButton disabled={!confirmed} pending={pending} pendingLabel="申請を開始中…" fullWidthOnMobile>団体申請を開始する</SubmitButton>
      </div>
    </form>
  );
}
