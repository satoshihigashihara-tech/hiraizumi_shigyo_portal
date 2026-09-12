import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { formatPeriod } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { getMyCampRoomAssignments } from "@/utils/camp-room-assignments/queries";
import styles from "./page.module.css";

export const metadata = {
  title: "キャンプの部屋｜ひらいずみ志業ポータル",
  description: "自分に割り当てられたキャンプの部屋を確認できます。",
};

function RoomState({ assignment }) {
  if (assignment.mode === "legacy_application") {
    return <AlertMessage tone="info" title="従来方式のキャンプです"><p>部屋はキャンプ申請詳細で確認してください。</p></AlertMessage>;
  }
  if (assignment.participationState === "ended" || assignment.placementState === "ended") {
    return <AlertMessage tone="warning" title="このキャンプへの参加は終了しています"><p>現在利用できる部屋はありません。</p></AlertMessage>;
  }
  if (assignment.placementState === "unassigned") {
    return <EmptyState title="部屋はまだ決まっていません" description="部屋が確定すると、この画面に自分の部屋だけが表示されます。" />;
  }
  return <div className={styles.assignment} aria-label="割り当てられた部屋">
    <p className={styles.roomLabel}>あなたの部屋</p>
    <p className={styles.roomName}>{assignment.roomName}</p>
    <dl className={styles.facts}>
      <div><dt>階</dt><dd>{assignment.floor}階</dd></div>
      <div><dt>利用期間</dt><dd>{formatPeriod(assignment.assignmentStartDate, assignment.assignmentEndDate)}</dd></div>
    </dl>
    {assignment.floor === 2 && <p className={styles.safetyNote}>2階の案内図は掲載していません。到着時は現地の案内表示または町の担当者の案内をご確認ください。</p>}
  </div>;
}

export default async function CampRoomPage() {
  const result = await getMyCampRoomAssignments();
  return <PageShell title="キャンプの部屋" description="ログイン中の本人に割り当てられた部屋だけを表示します。">
    <AlertMessage tone="info" title="表示内容について"><p>同じキャンプに参加するほかの方の氏名や部屋は表示されません。</p></AlertMessage>
    {result.error ? <AlertMessage tone="error" title="部屋情報を読み込めませんでした"><p>{errorMessage(result.error)}</p></AlertMessage>
      : result.assignments.length === 0 ? <EmptyState title="確認できるキャンプはありません" description="対象のキャンプに申し込むと、部屋の状態をここで確認できます。" />
        : <ul className={styles.list} role="list">{result.assignments.map((assignment) => <li className={styles.card} key={assignment.campId}>
          <h2>{assignment.campName}</h2>
          <p className={styles.campPeriod}>開催期間：{formatPeriod(assignment.startDate, assignment.endDate)}</p>
          <RoomState assignment={assignment} />
          {assignment.applicationId && <LinkButton href={`/user/applications/${assignment.applicationId}`} fullWidthOnMobile>キャンプ申請詳細を見る</LinkButton>}
        </li>)}</ul>}
    <div className={styles.actions}>
      <LinkButton href="/user/profile?mode=camp" fullWidthOnMobile>プロフィールへ戻る</LinkButton>
      <LinkButton href="/user?mode=camp" fullWidthOnMobile>利用者ホームへ戻る</LinkButton>
    </div>
  </PageShell>;
}
