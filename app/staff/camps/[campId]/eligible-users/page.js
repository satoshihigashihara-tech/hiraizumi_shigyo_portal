import { notFound } from "next/navigation";
import { addCampEligibleUsers } from "@/app/actions/staff-camps";
import AlertMessage from "@/app/components/AlertMessage";
import EmptyState from "@/app/components/EmptyState";
import FormField from "@/app/components/FormField";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import SubmitButton from "@/app/components/SubmitButton";
import { errorMessage } from "@/app/components/messages";
import { getCampEligibleRoster, getCampEligibleUsers, getStaffCamp } from "@/utils/staff-camps/queries";
import styles from "../../camps.module.css";
import EligibleUserForms from "./EligibleUserForms";

function first(value) { return Array.isArray(value) ? value[0] : value; }

export default async function EligibleUsersPage({ params, searchParams }) {
  const { campId } = await params;
  const query = (await searchParams) ?? {};
  const campResult = await getStaffCamp(campId);
  if (campResult.error === "not-found") notFound();
  const rosterMode = campResult.camp?.room_assignment_mode === "eligible_roster";
  const usersResult = rosterMode ? await getCampEligibleRoster(campId) : await getCampEligibleUsers(campId);
  if (usersResult.error === "not-found") notFound();
  const error = campResult.error || usersResult.error;
  const registered = Number(first(query.registered));
  const updated = first(query.updated);
  return <PageShell title="キャンプ対象者" description={campResult.camp ? `${campResult.camp.name}の${rosterMode ? "対象者名簿を管理します。" : "対象メールアドレスを登録します。"}` : "対象者を登録します。"}>
    {error && <AlertMessage tone="error" title="対象者を読み込めませんでした"><p>{errorMessage(error)}</p></AlertMessage>}
    {first(query.error) && <AlertMessage tone="error" title="対象者を登録できませんでした"><p>{errorMessage(first(query.error))}</p></AlertMessage>}
    {Number.isSafeInteger(registered) && registered >= 0 && <AlertMessage tone="success" title="対象者を登録しました"><p>{registered}件を登録しました。</p></AlertMessage>}
    {updated === "changed" && <AlertMessage tone="success" title="対象者を変更しました" />}
    {updated === "disabled" && <AlertMessage tone="success" title="対象者を無効にしました" />}
    {!error && (rosterMode ? <section aria-labelledby="eligible-list-title"><h2 id="eligible-list-title" className={styles.sectionTitle}>対象者名簿</h2>
      <EligibleUserForms campId={campId} users={usersResult.users} mode="roster" />
    </section> : <><form className={styles.form} action={addCampEligibleUsers}>
      <input type="hidden" name="campId" value={campId} />
      <FormField as="textarea" id="eligibleEmails" name="eligibleEmails" label="対象者のメールアドレス" required rows={5} maxLength={100000} hint="1行に1件入力します。空白・カンマ区切りでも登録できます。" />
      <SubmitButton pendingLabel="登録中…" fullWidthOnMobile>対象者を登録する</SubmitButton>
    </form>
    <section aria-labelledby="eligible-list-title"><h2 id="eligible-list-title" className={styles.sectionTitle}>登録済みの対象者</h2>
      {usersResult.users.length === 0 ? <EmptyState title="対象者はまだ登録されていません" description="上のフォームからメールアドレスを登録してください。" />
        : <EligibleUserForms campId={campId} users={usersResult.users} mode="legacy" />}
    </section></>)}
    <div><LinkButton href={`/staff/camps/${campId}`}>キャンプ詳細へ戻る</LinkButton></div>
  </PageShell>;
}
