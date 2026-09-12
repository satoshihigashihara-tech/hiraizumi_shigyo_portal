import { notFound } from "next/navigation";
import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import StatusBadge from "@/app/components/StatusBadge";
import { formatJstDateTime, formatPeriod } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import {
  getStaffCommunityGroupCancellation,
  getStaffCommunityGroupReview,
} from "@/utils/community-groups/staff-queries";
import { GroupReviewOperations } from "./GroupReviewForms";
import styles from "../groups.module.css";

export const metadata = { title: "団体申請の審査詳細｜ひらいずみ志業ポータル" };

const UPDATED_MESSAGES = {
  confirm_purpose: "利用目的を確認済みにしました。",
  reject: "団体申請を不許可にしました。",
  approve: "団体申請を許可しました。",
  rooms: "部屋別人数を保存しました。",
  "participant-start_review": "参加者の審査を開始しました。",
  "participant-request_revision": "参加者へ修正を依頼しました。",
  "participant-approve": "参加者の申請を許可しました。",
  "participant-rejected": "参加者を不許可にし、団体へ交代を依頼しました。",
  cancelled: "団体申請の取消を確定しました。",
  "participant-cancelled": "許可済み参加者の減員を保存しました。",
};

function Fact({ label, children }) {
  return <div><dt>{label}</dt><dd>{children ?? "未設定"}</dd></div>;
}

export default async function StaffCommunityGroupPage({ params, searchParams }) {
  const [{ groupId }, query] = await Promise.all([params, searchParams]);
  const [reviewResult, cancellationResult] = await Promise.all([
    getStaffCommunityGroupReview(groupId),
    getStaffCommunityGroupCancellation(groupId),
  ]);
  if (reviewResult.error === "not-found" || cancellationResult.error === "not-found") notFound();
  if (reviewResult.error || !reviewResult.group) {
    return (
      <PageShell title="団体申請の審査詳細">
        <AlertMessage tone="error" title="団体申請を開けませんでした"><p>{errorMessage(reviewResult.error)}</p></AlertMessage>
        <LinkButton href="/staff/community/groups">団体申請の一覧へ戻る</LinkButton>
      </PageShell>
    );
  }

  const group = reviewResult.group;
  const updated = typeof query?.updated === "string" ? query.updated : null;
  const success = updated && Object.hasOwn(UPDATED_MESSAGES, updated) ? UPDATED_MESSAGES[updated] : null;
  const activeAllocations = group.allocations.filter((allocation) => allocation.released_from === null);
  const approvedCount = group.participants.filter((participant) => participant.status === "approved").length;
  const allocatedCount = activeAllocations.reduce((sum, allocation) => sum + allocation.people_count, 0);

  return (
    <PageShell title="団体申請の審査詳細" description={group.group_name || "団体名未設定"}>
      {success && <AlertMessage tone="success" title={success} />}
      {cancellationResult.error && (
        <AlertMessage tone="error" title="取消申請の状況を読み込めませんでした"><p>{errorMessage(cancellationResult.error)}</p></AlertMessage>
      )}
      <StatusBadge kind="group" value={group.status} showKind />

      <section className={styles.panel} aria-labelledby="review-order-heading">
        <h2 id="review-order-heading">審査の順序</h2>
        <ol className={styles.stepList}>
          <li>団体の利用目的と町内で行う活動を確認する</li>
          <li>参加者ごとの申請を審査する</li>
          <li>参加者数と一致する部屋別人数を保存する</li>
          <li>すべて確認後に団体を許可する</li>
        </ol>
        <dl className={styles.facts}>
          <Fact label="目的確認">{group.purpose_reviewed_at ? `確認済み（${formatJstDateTime(group.purpose_reviewed_at)}）` : "未確認"}</Fact>
          <Fact label="参加者の許可">{approvedCount}人 / {group.participants.length}人</Fact>
          <Fact label="部屋割当人数">{allocatedCount}人 / {group.participants.length}人</Fact>
          <Fact label="予定人数">{group.planned_participants}人</Fact>
        </dl>
      </section>

      <section className={styles.panel} aria-labelledby="group-information-heading">
        <h2 id="group-information-heading">団体の申請内容</h2>
        <dl className={styles.facts}>
          <Fact label="団体名">{group.group_name || "団体名未設定"}</Fact>
          <Fact label="利用期間">{formatPeriod(group.start_date, group.end_date)}</Fact>
          <Fact label="利用目的">{group.purpose || "未入力"}</Fact>
          <Fact label="町内で行う活動">{group.local_activity || "未入力"}</Fact>
        </dl>
      </section>

      {activeAllocations.length > 0 && (
        <section className={styles.panel} aria-labelledby="current-rooms-heading">
          <h2 id="current-rooms-heading">現在の部屋別人数</h2>
          <dl className={styles.facts}>
            {activeAllocations.map((allocation) => <Fact key={allocation.room_id} label={allocation.room_name}>{allocation.people_count}人</Fact>)}
          </dl>
        </section>
      )}

      <GroupReviewOperations group={group} cancellation={cancellationResult.cancellation} />

      <div className={styles.actions}>
        <LinkButton href="/staff/community/groups" fullWidthOnMobile>団体申請の一覧へ戻る</LinkButton>
        <LinkButton href="/staff" fullWidthOnMobile>職員ホームへ戻る</LinkButton>
      </div>
    </PageShell>
  );
}
