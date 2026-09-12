import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge from "@/app/components/StatusBadge";
import { formatDeadline } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { getCommunityGroupParticipants } from "@/utils/group-invitations/queries";
import InvitePanel from "./InvitePanel";
import ParticipantRemovalForm from "./ParticipantRemovalForm";
import styles from "../../groups.module.css";

export const metadata = { title: "参加者と招待｜ひらいずみ志業ポータル" };

export default async function GroupParticipantsPage({ params, searchParams }) {
  const { groupId } = await params;
  const query = (await searchParams) ?? {};
  const result = await getCommunityGroupParticipants(groupId);
  if (result.error === "not-found") notFound();
  if (result.error || !result.group) {
    return <PageShell title="参加者と招待"><AlertMessage tone="error" title="参加者情報を開けませんでした"><p>{errorMessage(result.error)}</p></AlertMessage><LinkButton href="/user/groups" fullWidthOnMobile>団体一覧へ戻る</LinkButton></PageShell>;
  }

  const group = result.group;
  const joinedCount = group.participants.length;
  const canManageParticipants = ["collecting", "revision_requested"].includes(group.status);
  const canInvite = group.status === "collecting" && joinedCount < group.planned_participants;
  const canRemoveParticipant = (participant) => !participant.is_representative && (
    (group.status === "collecting" && ["draft", "submitted"].includes(participant.application_status))
    || (group.status === "revision_requested" && ["revision_requested", "rejected"].includes(participant.application_status))
  );

  return (
    <PageShell title="参加者と招待" description={group.group_name}>
      <StatusBadge kind="group" value={group.status} showKind />
      {query.updated === "participant-removed" && (
        <AlertMessage tone="success" title="参加者を削除しました">
          <p>交代する場合は、新しい招待を発行して後任の方へ共有してください。</p>
        </AlertMessage>
      )}
      <section className={styles.panel} aria-labelledby="progress-heading">
        <h2 id="progress-heading">参加状況</h2>
        <p className={styles.note}>代表者本人も宿泊する設定の場合は、代表者も招待リンクから参加手続きを行ってください。</p>
        <dl className={styles.facts}>
          <div><dt>参加済み</dt><dd className={styles.count}>{joinedCount}人 / {group.planned_participants}人</dd></div>
          <div><dt>参加者提出期限</dt><dd>{group.participant_due_at ? formatDeadline(group.participant_due_at) : "なし"}</dd></div>
        </dl>
      </section>

      {canInvite ? <InvitePanel groupId={group.group_id} updatedAt={group.updated_at} /> : (
        <AlertMessage tone="info" title="招待は現在利用できません">
          <p>{joinedCount >= group.planned_participants ? "予定人数に達しています。" : "団体の現在の状態では招待を発行できません。"}</p>
        </AlertMessage>
      )}

      <section className={styles.panel} aria-labelledby="participants-heading">
        <h2 id="participants-heading">参加者</h2>
        {!canManageParticipants && (
          <AlertMessage tone="info" title="参加者の削除・交代は現在利用できません">
            <p>団体の審査状況が変わった後の参加者変更は、町の担当へお問い合わせください。</p>
          </AlertMessage>
        )}
        {group.participants.length ? (
          <ul className={styles.participantList}>
            {group.participants.map((participant) => (
              <li className={styles.participantCard} key={participant.application_id}>
                <div className={styles.participantHeader}>
                  <h3>{participant.name || "氏名未入力"}</h3>
                  <StatusBadge kind="application" value={participant.application_status} />
                </div>
                {participant.is_representative && <p className={styles.note}>団体代表者</p>}
                {canRemoveParticipant(participant) && (
                  <ParticipantRemovalForm groupId={group.group_id} applicationId={participant.application_id}
                    updatedAt={group.updated_at} participantName={participant.name} />
                )}
              </li>
            ))}
          </ul>
        ) : <EmptyState title="参加者はまだいません" description="招待情報を参加予定者へ共有してください。" />}
      </section>

      <div className={styles.actions}>
        <LinkButton href={`/user/groups/${group.group_id}`} fullWidthOnMobile>団体詳細へ戻る</LinkButton>
      </div>
    </PageShell>
  );
}
