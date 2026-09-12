"use client";

import { useActionState, useState } from "react";
import { issueCommunityGroupInvite } from "@/app/actions/group-invitations";
import AlertMessage from "@/app/components/AlertMessage";
import buttonStyles from "@/app/components/Button.module.css";
import { formatDeadline } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import styles from "../../groups.module.css";

async function issueInvite(_previousState, formData) {
  return issueCommunityGroupInvite(formData);
}

export default function InvitePanel({ groupId, updatedAt }) {
  const [state, formAction, pending] = useActionState(issueInvite, null);
  const [copyStatus, setCopyStatus] = useState("");
  const invite = state?.invite ?? null;
  const currentVersion = invite?.groupUpdatedAt ?? updatedAt;
  const invitePath = invite?.token ? `/invite/${invite.token}` : "";

  async function copy(value, label, absolute = false) {
    try {
      const copyValue = absolute ? new URL(value, window.location.origin).href : value;
      await navigator.clipboard.writeText(copyValue);
      setCopyStatus(`${label}をコピーしました。`);
    } catch {
      setCopyStatus("コピーできませんでした。文字列を選択してコピーしてください。");
    }
  }

  return (
    <section className={styles.panel} aria-labelledby="invite-heading">
      <h2 id="invite-heading">参加者を招待する</h2>
      <p className={styles.note}>
        発行すると、それまでの招待リンクとコードは使えなくなります。新しい招待情報はこの画面で一度だけ表示します。
      </p>

      {state?.error && (
        <AlertMessage tone="error" title="招待を発行できませんでした">
          <p>{errorMessage(state.error)}</p>
        </AlertMessage>
      )}

      {invite && (
        <div className={styles.inviteResult} role="status" aria-labelledby="invite-result-heading">
          <h3 id="invite-result-heading">新しい招待情報</h3>
          <p>
            この情報は再表示できません。参加者へ共有するまで、この画面を閉じないでください。
          </p>
          <div className={styles.inviteSecret}>
            <label htmlFor="invite-url">招待リンク</label>
            <div className={styles.copyRow}>
              <input id="invite-url" readOnly value={invitePath} />
              <button className={`${buttonStyles.button} ${buttonStyles.secondary}`} type="button" onClick={() => copy(invitePath, "招待リンク", true)}>
                リンクをコピー
              </button>
            </div>
          </div>
          <div className={styles.inviteSecret}>
            <label htmlFor="invite-code">招待コード</label>
            <div className={styles.copyRow}>
              <input className={styles.code} id="invite-code" readOnly value={invite.code} />
              <button className={`${buttonStyles.button} ${buttonStyles.secondary}`} type="button" onClick={() => copy(invite.code, "招待コード")}>
                コードをコピー
              </button>
            </div>
          </div>
          <p>有効期限：{formatDeadline(invite.expiresAt)}</p>
          <p className={styles.copyStatus} aria-live="polite">{copyStatus}</p>
        </div>
      )}

      <form action={formAction}>
        <input type="hidden" name="groupId" value={groupId} />
        <input type="hidden" name="updatedAt" value={currentVersion} />
        <button className={`${buttonStyles.button} ${buttonStyles.primary} ${buttonStyles.fullWidthOnMobile}`} disabled={pending} type="submit">
          {pending ? "招待を発行中…" : invite ? "招待を再発行する" : "招待を発行する"}
        </button>
      </form>
    </section>
  );
}
