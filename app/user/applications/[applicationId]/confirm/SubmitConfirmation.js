"use client";

import { useActionState, useState } from "react";
import { submitCampApplication } from "@/app/actions/camp-applications";
import { submitCommunityApplication } from "@/app/actions/community-applications";
import AlertMessage from "@/app/components/AlertMessage";
import { errorMessage } from "@/app/components/messages";
import LinkButton from "@/app/components/LinkButton";
import SubmitButton from "@/app/components/SubmitButton";
import styles from "../application-view.module.css";

async function submitCampState(_previousState, formData) {
  return submitCampApplication(formData);
}

async function submitCommunityState(_previousState, formData) {
  return submitCommunityApplication(formData);
}

export default function SubmitConfirmation({ applicationId, usageType = "camp", updatedAt, submissionKey }) {
  const [confirmed, setConfirmed] = useState(false);
  const [state, formAction, pending] = useActionState(
    usageType === "community_individual" ? submitCommunityState : submitCampState,
    { error: null },
  );

  return (
    <form className={styles.submissionPanel} action={formAction}>
      <input type="hidden" name="applicationId" value={applicationId} />
      {updatedAt && <input type="hidden" name="updatedAt" value={updatedAt} />}
      {submissionKey && <input type="hidden" name="submissionKey" value={submissionKey} />}
      {state?.error && <AlertMessage tone="error" title="申請を提出できませんでした"><p>{errorMessage(state.error)}</p></AlertMessage>}
      <label className={styles.confirmationLabel}>
        <input
          type="checkbox"
          name="confirmed"
          value="true"
          checked={confirmed}
          onChange={(event) => setConfirmed(event.target.checked)}
          required
        />
        <span>入力内容を確認し、申請を提出します</span>
      </label>
      <p className={styles.submissionNote}>
        提出後は職員が内容を審査します。この操作だけでは利用は確定しません。
      </p>
      <div className={styles.actions}>
        <LinkButton
          href={`/user/applications/${applicationId}/edit`}
          variant="secondary"
          fullWidthOnMobile
        >
          入力へ戻る
        </LinkButton>
        <SubmitButton
          disabled={!confirmed}
          pending={pending}
          pendingLabel="提出中…"
          fullWidthOnMobile
        >
          申請を提出する
        </SubmitButton>
      </div>
    </form>
  );
}
