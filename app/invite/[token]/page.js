import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { formatDeadline, formatPeriod } from "@/app/components/format";
import { errorMessage } from "@/app/components/messages";
import { getCommunityGroupInvite } from "@/utils/group-invitations/queries";
import { normalizeInvite } from "@/utils/group-invitations/validation";
import styles from "@/app/user/groups/groups.module.css";
import JoinGroupForm from "./JoinGroupForm";

export const metadata = {
  title: "団体の招待内容を確認｜ひらいずみ志業ポータル",
  description: "招待された団体の内容を確認して参加します。",
};

export default async function InviteDetailPage({ params }) {
  const { token: rawValue } = await params;
  const token = normalizeInvite(rawValue, "token");
  const code = token ? null : normalizeInvite(rawValue, "code");
  const inviteKind = token ? "token" : code ? "code" : null;
  const inviteValue = token ?? code;

  if (!inviteKind || !inviteValue) {
    return (
      <PageShell title="招待内容を確認できませんでした">
        <AlertMessage tone="error" title="招待リンクまたはコードが正しくありません">
          <p>{errorMessage("invalid-invite")}</p>
        </AlertMessage>
        <LinkButton href="/invite" fullWidthOnMobile>招待コードを入力し直す</LinkButton>
      </PageShell>
    );
  }

  const returnTo = `/invite/${inviteValue}`;
  const result = await getCommunityGroupInvite(inviteValue, inviteKind, returnTo);

  if (result.error || !result.invite) {
    return (
      <PageShell title="招待内容を確認できませんでした">
        <AlertMessage tone="error" title="この招待を利用できません">
          <p>{errorMessage(result.error)}</p>
        </AlertMessage>
        <LinkButton href="/invite" fullWidthOnMobile>別の招待コードを入力する</LinkButton>
      </PageShell>
    );
  }

  const invite = result.invite;
  const alreadyJoined = invite.already_joined_application_id;

  return (
    <PageShell
      title="団体の招待内容を確認"
      description="団体名と利用内容に間違いがないか確認してください。"
    >
      <section className={styles.panel} aria-labelledby="invite-group-heading">
        <h2 id="invite-group-heading">{invite.group_name}</h2>
        <dl className={styles.facts}>
          <div><dt>利用期間</dt><dd>{formatPeriod(invite.start_date, invite.end_date)}</dd></div>
          <div><dt>参加者の提出期限</dt><dd>{formatDeadline(invite.participant_due_at)}</dd></div>
          <div><dt>予定人数</dt><dd>{invite.planned_participants}人</dd></div>
          <div><dt>現在の参加人数</dt><dd>{invite.joined_participants}人</dd></div>
          <div><dt>使用目的</dt><dd>{invite.purpose}</dd></div>
          <div><dt>平泉町内で行う活動</dt><dd>{invite.local_activity}</dd></div>
        </dl>
      </section>

      {alreadyJoined ? (
        <AlertMessage tone="success" title="この団体には参加済みです">
          <p>続けて、本人情報と緊急連絡先を入力してください。</p>
          <LinkButton href={`/user/applications/${alreadyJoined}/edit`} fullWidthOnMobile>
            個人情報の入力へ進む
          </LinkButton>
        </AlertMessage>
      ) : invite.can_join ? (
        <JoinGroupForm
          inviteValue={inviteValue}
          inviteKind={inviteKind}
          applicationId={crypto.randomUUID()}
        />
      ) : (
        <AlertMessage tone="warning" title="現在はこの団体に参加できません">
          <p>予定人数や提出期限が変更されている可能性があります。団体代表者へご確認ください。</p>
        </AlertMessage>
      )}

      <div className={styles.actions}>
        <LinkButton href="/invite" fullWidthOnMobile>別の招待コードを入力する</LinkButton>
        <LinkButton href="/user" fullWidthOnMobile>利用者ホームへ戻る</LinkButton>
      </div>
    </PageShell>
  );
}
