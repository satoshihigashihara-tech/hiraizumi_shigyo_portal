"use client";

import { useActionState, useEffect, useRef } from "react";
import { requestCommunityApplicationCancellation } from "@/app/actions/community-applications";
import AlertMessage from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "../page.module.css";

async function requestCancellation(_previousState, formData) {
  return requestCommunityApplicationCancellation(formData);
}

export default function CancellationForm({ applicationId, updatedAt }) {
  const [state, formAction, pending] = useActionState(requestCancellation, null);
  const summaryRef = useRef(null);

  useEffect(() => {
    if (!state?.error) return;
    const target = state.fieldErrors?.reason
      ? document.getElementById("community-cancellation-reason")
      : summaryRef.current;
    target?.focus();
  }, [state]);

  return (
    <form className={styles.operationForm} action={formAction} noValidate>
      <input type="hidden" name="applicationId" value={applicationId} />
      <input type="hidden" name="updatedAt" value={updatedAt} />

      {state?.error && (
        <div ref={summaryRef} tabIndex={-1} className={styles.focusTarget}>
          <AlertMessage tone="error" title="取消を申請できませんでした">
            <p>{errorMessage(state.error)}</p>
          </AlertMessage>
        </div>
      )}

      <FormField
        as="textarea"
        id="community-cancellation-reason"
        name="reason"
        label="取消理由"
        hint="町の職員が確認できるよう、取消を希望する理由を入力してください。"
        required
        rows={5}
        maxLength={2000}
        defaultValue={state?.fields?.reason ?? ""}
        error={state?.fieldErrors?.reason}
      />
      <div className={styles.actions}>
        <SubmitButton variant="danger" pending={pending} pendingLabel="取消申請中…" fullWidthOnMobile>
          取消を申請する
        </SubmitButton>
      </div>
    </form>
  );
}
