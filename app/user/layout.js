import styles from "./layout.module.css";
import { requireActiveUser } from "@/utils/auth/guards";
import { currentReturnTo } from "@/utils/navigation/request-context";
import SessionTimeout from "@/app/components/SessionTimeout";
import { sessionTimeoutMs } from "@/utils/auth/session-timeout";

export const metadata = { title: "利用者メニュー｜ひらいずみ志業ポータル" };

// レイアウト境界と、各データ取得・Server Action のDALで認可を確認する。
export default async function UserLayout({ children }) {
  await requireActiveUser(await currentReturnTo("/user"));
  return <div className={styles.layout}>
    <SessionTimeout durationMs={sessionTimeoutMs(process.env.NODE_ENV, process.env.SESSION_TIMEOUT_MS)} />
    {children}
  </div>;
}
