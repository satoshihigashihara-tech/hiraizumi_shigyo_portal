import { errorMessage } from "@/app/components/messages";
export function campReviewMessage(code) {
  return ({ "submitted-pdf-inconsistent": "提出PDFと現在の申請・部屋が一致しません。最新の提出内容を確認してください。",
    "invalid-expectations": "確認時の情報を読み取れませんでした。画面を再読み込みしてください。",
    "stale-update": "他の操作で情報が更新されました。入力を控え、画面を再読み込みして変更前後を確認してください。",
    "camp-started": "キャンプ開始前に操作してください。",
    "confirmation-required": "変更前後と対象者を確認してください。",
  })[code] || errorMessage(code);
}
