import LinkButton from "@/app/components/LinkButton";
import PageShell from "@/app/components/PageShell";
import AlertMessage from "@/app/components/AlertMessage";
import { errorMessage } from "@/app/components/messages";
import { getUserProfile } from "@/utils/profile/queries";
import CommunityApplicationForm from "../../[applicationId]/edit/CommunityApplicationForm";

export const metadata = {
  title: "地域活動の個人申請｜ひらいずみ志業ポータル",
  description: "地域活動利用の期間と申請内容を入力します。",
};

function first(value) {
  return Array.isArray(value) ? value[0] : value;
}

export default async function NewCommunityApplicationPage({ searchParams }) {
  const query = (await searchParams) ?? {};
  const profileResult = await getUserProfile("/user/applications/new/community-activity");
  const initialFields = {
    applicantName: profileResult.profile?.fullName ?? "",
    applicantAddress: profileResult.profile?.address ?? "",
    applicantPhone: profileResult.profile?.phone ?? "",
    emergencyContactName: profileResult.profile?.emergencyName ?? "",
    emergencyContactAddress: profileResult.profile?.emergencyAddress ?? "",
    emergencyContactPhone: profileResult.profile?.emergencyPhone ?? "",
    startDate: first(query.start) ?? "",
    endDate: first(query.end) ?? "",
    usagePlace: "common_and_second_floor",
  };

  return (
    <PageShell title="地域活動の個人申請" description="町内で行う活動と利用期間を入力してください。保存ボタンを押すまでは下書きを作成しません。">
      {profileResult.error && <AlertMessage tone="warning" title="プロフィールを読み込めませんでした">
        <p>{errorMessage(profileResult.error)} 必要な本人情報をこの画面で入力してください。</p>
      </AlertMessage>}
      <CommunityApplicationForm applicationId={crypto.randomUUID()} initialFields={initialFields} mode="create" />
      <LinkButton href="/user/applications/new" fullWidthOnMobile>申請方法の選択へ戻る</LinkButton>
    </PageShell>
  );
}
