"use client";

import { useActionState, useEffect, useRef } from "react";
import { createCommunityApplicationExtension } from "@/app/actions/community-applications";
import AlertMessage from "@/app/components/AlertMessage";
import FormField from "@/app/components/FormField";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import styles from "../page.module.css";

async function createExtension(_previousState, formData) {
  return createCommunityApplicationExtension(formData);
}

export default function ExtensionForm({ extensionId, originalApplicationId, startDate, maximumEndDate }) {
  const [state, formAction, pending] = useActionState(createExtension, null);
  const summaryRef = useRef(null);

  useEffect(() => {
    if (!state?.error) return;
    const target = state.fieldErrors?.endDate
      ? document.getElementById("community-extension-end-date")
      : state.fieldErrors?.reason
        ? document.getElementById("community-extension-reason")
        : summaryRef.current;
    target?.focus();
  }, [state]);

  return (
    <form className={styles.operationForm} action={formAction} noValidate>
      <input type="hidden" name="extensionId" value={extensionId} />
      <input type="hidden" name="originalApplicationId" value={originalApplicationId} />

      {state?.error && (
        <div ref={summaryRef} tabIndex={-1} className={styles.focusTarget}>
          <AlertMessage tone="error" title="継続申請を開始できませんでした">
            <p>{errorMessage(state.error)}</p>
          </AlertMessage>
        </div>
      )}

      <FormField
        id="community-extension-end-date"
        name="endDate"
        label="継続後の利用終了日"
        type="date"
        required
        min={startDate}
        max={maximumEndDate}
        defaultValue={state?.fields?.endDate ?? startDate}
        error={state?.fieldErrors?.endDate}
      />
      <p className={styles.note}>入力できる期間は{startDate}から{maximumEndDate}までです。</p>
      <FormField
        as="textarea"
        id="community-extension-reason"
        name="reason"
        label="継続理由"
        hint="継続して利用する必要がある理由を入力してください。"
        required
        rows={5}
        maxLength={2000}
        defaultValue={state?.fields?.reason ?? ""}
        error={state?.fieldErrors?.reason}
      />
      <div className={styles.actions}>
        <SubmitButton pending={pending} pendingLabel="継続申請を準備中…" fullWidthOnMobile>
          継続申請を開始する
        </SubmitButton>
      </div>
    </form>
  );
}
