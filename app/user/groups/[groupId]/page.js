import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge from "@/app/components/StatusBadge";
import { formatDeadline, formatJstDateTime } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { statusLabel } from "@/app/components/status-labels";
import { getCommunityGroup, getCommunityGroupCancellation } from "@/utils/community-groups/queries";
import GroupReview from "../GroupReview";
import GroupCancellationForm from "./GroupCancellationForm";
import styles from "../groups.module.css";

export const metadata = { title: "団体申請詳細｜ひらいずみ志業ポータル" };

export default async function GroupDetailPage({ params, searchParams }) {
  const { groupId } = await params;
  const query = (await searchParams) ?? {};
  const [result, cancellationResult] = await Promise.all([
    getCommunityGroup(groupId, "detail"),
    getCommunityGroupCancellation(groupId),
  ]);
  if (result.error === "not-found") notFound();
  if (result.error || !result.group) return <PageShell title="団体申請詳細"><AlertMessage tone="error" title="団体申請を開けませんでした"><p>{errorMessage(result.error)}</p></AlertMessage><LinkButton href="/user/groups" fullWidthOnMobile>団体一覧へ戻る</LinkButton></PageShell>;
  const group = result.group;
  return <PageShell title="団体申請詳細" description={group.fields.group_name}>
    <StatusBadge kind="group" value={group.status} showKind />
    {query.updated === "cancellation-requested" && <AlertMessage tone="success" title="団体の取消を申請しました"><p>町の職員による確認結果をお待ちください。</p></AlertMessage>}
    {group.status === "collecting" && <AlertMessage tone="info" title="次にすること"><p>参加予定者へ招待リンクまたはコードを共有してください。</p>{group.participant_due_at && <p>参加者提出期限：{formatDeadline(group.participant_due_at)}</p>}</AlertMessage>}
    {group.status === "draft" && <AlertMessage tone="info" title="次にすること"><p>団体情報を確認し、申請を開始してください。</p></AlertMessage>}
    {group.status === "cancellation_requested" && <AlertMessage tone="info" title="取消申請を確認中です"><p>町の職員による確認結果をお待ちください。</p></AlertMessage>}
    {group.reception_number && <section className={styles.panel} aria-labelledby="receipt-heading"><h2 id="receipt-heading">受付情報</h2><dl className={styles.facts}>
      <div><dt>受付番号</dt><dd className={styles.reception}>{group.reception_number}</dd></div>
      <div><dt>申請開始日時</dt><dd>{group.submitted_at ? formatJstDateTime(group.submitted_at) : "未提出"}</dd></div>
      <div><dt>参加者提出期限</dt><dd>{group.participant_due_at ? formatDeadline(group.participant_due_at) : "なし"}</dd></div>
    </dl></section>}
    <GroupReview group={group} />
    <section className={styles.panel} aria-labelledby="history-heading"><h2 id="history-heading">団体状態の履歴</h2>{group.events.length ? <ol className={styles.history}>{group.events.map((event, index) => <li key={`${event.occurred_at}-${index}`}><p>{event.from_status ? `${statusLabel("group", event.from_status)} → ` : ""}<strong>{statusLabel("group", event.to_status)}</strong></p>{event.public_reason && <p>{event.public_reason}</p>}<time dateTime={event.occurred_at}>{formatJstDateTime(event.occurred_at)}</time></li>)}</ol> : <EmptyState title="履歴はまだありません" />}</section>
    {cancellationResult.error && <AlertMessage tone="error" title="取消の受付状態を確認できませんでした"><p>{errorMessage(cancellationResult.error)}</p></AlertMessage>}
    {cancellationResult.cancellation?.can_request && <GroupCancellationForm groupId={group.id} updatedAt={cancellationResult.cancellation.updated_at} />}
    {!cancellationResult.error && cancellationResult.cancellation && !cancellationResult.cancellation.can_request
      && ["under_review", "revision_requested", "approved"].includes(group.status)
      && <AlertMessage tone="info" title="画面から取消申請できません"><p>利用開始後の変更などは、町の担当へお問い合わせください。</p></AlertMessage>}
    <div className={styles.actions}>{group.status === "draft" && <LinkButton href={`/user/groups/${group.id}/edit`} variant="primary" fullWidthOnMobile>団体情報を編集する</LinkButton>}{group.status === "collecting" && <LinkButton href={`/user/groups/${group.id}/participants`} variant="primary" fullWidthOnMobile>参加者を招待する</LinkButton>}<LinkButton href="/user/groups" fullWidthOnMobile>団体一覧へ戻る</LinkButton></div>
  </PageShell>;
}
