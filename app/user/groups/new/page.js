import AlertMessage from "@/app/components/AlertMessage";
import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import { errorMessage } from "@/app/components/messages";
import { getUserProfile } from "@/utils/profile/queries";
import GroupForm from "../[groupId]/edit/GroupForm";

export const metadata = { title: "団体申請｜ひらいずみ志業ポータル" };

const first = (value) => Array.isArray(value) ? value[0] : value;

export default async function NewGroupPage({ searchParams }) {
  const query = (await searchParams) ?? {};
  const profile = await getUserProfile("/user/groups/new");
  const initialFields = {
    representativeName: profile.profile?.fullName ?? "",
    representativeAddress: profile.profile?.address ?? "",
    representativePhone: profile.profile?.phone ?? "",
    startDate: first(query.start) ?? "",
    endDate: first(query.end) ?? "",
    usagePlace: "common_and_second_floor",
  };
  return (
    <PageShell audienceMode="fieldwork" title="地域活動の団体申請" description="団体情報、利用期間、予定人数を入力してください。保存するまでは下書きを作成しません。">
      {profile.error && <AlertMessage tone="warning" title="プロフィールを読み込めませんでした"><p>{errorMessage(profile.error)} 代表者情報を入力してください。</p></AlertMessage>}
      <GroupForm groupId={crypto.randomUUID()} initialFields={initialFields} mode="create" />
      <LinkButton href="/user/applications/new" fullWidthOnMobile>申請方法の選択へ戻る</LinkButton>
    </PageShell>
  );
}
