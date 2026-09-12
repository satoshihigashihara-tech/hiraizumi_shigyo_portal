"use client";

import { useActionState, useState } from "react";
import { joinCommunityGroup } from "@/app/actions/group-invitations";
import AlertMessage from "@/app/components/AlertMessage";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "@/app/user/groups/groups.module.css";

async function joinGroup(_previousState, formData) {
  return joinCommunityGroup(formData);
}

export default function JoinGroupForm({ inviteValue, inviteKind, applicationId }) {
  const [confirmed, setConfirmed] = useState(false);
  const [state, formAction, pending] = useActionState(joinGroup, { error: null });

  return (
    <form className={styles.submissionPanel} action={formAction}>
      <input type="hidden" name="inviteValue" value={inviteValue} />
      <input type="hidden" name="inviteKind" value={inviteKind} />
      <input type="hidden" name="applicationId" value={applicationId} />

      {state?.error && (
        <AlertMessage tone="error" title="団体に参加できませんでした">
          <p>{errorMessage(state.error)}</p>
        </AlertMessage>
      )}

      <label className={styles.participantHeader}>
        <input
          type="checkbox"
          name="confirmed"
          value="true"
          checked={confirmed}
          onChange={(event) => setConfirmed(event.target.checked)}
          required
        />
        <span>表示された団体と利用日程を確認しました</span>
      </label>
      <p className={styles.note}>
        参加後は、本人情報と緊急連絡先を入力して個別の申請を提出します。
      </p>
      <SubmitButton
        disabled={!confirmed}
        pending={pending}
        pendingLabel="団体に参加中…"
        fullWidthOnMobile
      >
        この団体に参加する
      </SubmitButton>
    </form>
  );
}
