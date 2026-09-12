"use client";

import { useActionState, useEffect, useRef } from "react";
import { removeCommunityGroupParticipant } from "@/app/actions/group-invitations";
import AlertMessage from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "../../groups.module.css";

async function removeParticipant(_previousState, formData) {
  return removeCommunityGroupParticipant(formData);
}

export default function ParticipantRemovalForm({ groupId, applicationId, updatedAt, participantName }) {
  const [state, formAction, pending] = useActionState(removeParticipant, null);
  const summaryRef = useRef(null);
  const reasonId = `removal-reason-${applicationId}`;
  const confirmationId = `removal-confirmed-${applicationId}`;

  useEffect(() => {
    if (!state?.error) return;
    const target = state.fieldErrors?.reason ? document.getElementById(reasonId)
      : state.fieldErrors?.confirmed ? document.getElementById(confirmationId) : summaryRef.current;
    target?.focus();
  }, [state, reasonId, confirmationId]);

  return (
    <details className={styles.participantOperation}>
      <summary>この参加者を削除・交代する</summary>
      <form className={styles.operationForm} action={formAction} noValidate>
        <input type="hidden" name="groupId" value={groupId} />
        <input type="hidden" name="applicationId" value={applicationId} />
        <input type="hidden" name="updatedAt" value={updatedAt} />

        <AlertMessage tone="warning" title="削除後は元に戻せません">
          <p>{participantName || "この参加者"}の申請はキャンセルされ、現在の招待情報も無効になります。</p>
          <p>交代する場合は削除後に新しい招待を発行し、後任の方へ共有してください。</p>
        </AlertMessage>

        {state?.error && (
          <div ref={summaryRef} tabIndex={-1} className={styles.focusTarget}>
            <AlertMessage tone="error" title="参加者を削除できませんでした">
              <p>{errorMessage(state.error)}</p>
            </AlertMessage>
          </div>
        )}

        <FormField as="textarea" id={reasonId} name="reason" label="削除・交代の理由" required rows={3}
          maxLength={2000} defaultValue={state?.fields?.reason ?? ""} error={state?.fieldErrors?.reason} />
        <FormField as="checkbox" id={confirmationId} name="confirmed"
          label={`${participantName || "この参加者"}を団体から削除することを確認しました`}
          required error={state?.fieldErrors?.confirmed} />
        <div className={styles.actions}>
          <SubmitButton variant="danger" pending={pending} pendingLabel="削除中…" fullWidthOnMobile>
            参加者を削除する
          </SubmitButton>
        </div>
      </form>
    </details>
  );
}
