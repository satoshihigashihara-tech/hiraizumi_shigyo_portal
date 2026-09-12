import styles from "./layout.module.css";
import { requireStaff } from "@/utils/auth/guards";
import { currentReturnTo } from "@/utils/navigation/request-context";

export const metadata = { title: "職員メニュー｜ひらいずみ志業ポータル" };

// レイアウト境界と、各データ取得・Server Action のDALで認可を確認する。
export default async function StaffLayout({ children }) {
  await requireStaff(await currentReturnTo("/staff"));
  return <div className={styles.layout}>{children}</div>;
}
