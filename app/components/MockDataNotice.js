import AlertMessage from "./AlertMessage";
import { MOCK_NOTICE_TEXT } from "./messages";

/**
 * 仮データを表示していることの明示。Server Component。
 *
 * mock-data.js を使う画面は必ずこれを置く。レビュー時と結合時に
 * 「実データが表示されている」と取り違えるのを防ぐ。
 * バックエンド接続が済んだ画面からは削除する。
 *
 * @param {object} props
 * @param {React.ReactNode} [props.children] 未接続箇所の補足説明
 */
export default function MockDataNotice({ children }) {
  return (
    <AlertMessage tone="info" title="開発用の仮データです">
      <p>{MOCK_NOTICE_TEXT}</p>
      {children}
    </AlertMessage>
  );
}
