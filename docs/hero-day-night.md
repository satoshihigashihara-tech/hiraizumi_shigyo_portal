# シェアハウスの朝 → 昼 → 夜

PR #119 (`codex/landing-page`, `2e2277e`) を基準に、`codex/hero-day-night` で実装。

## 動作と配信

- 最初は朝。3枚の画像の decode 完了と、画像領域が25%以上画面に入ることを待って再生。
- 0–0.3秒は朝、0.3–1.29秒で昼へ、1.29–1.59秒は昼、1.59–3秒で夜へ。夜は元写真の窓・玄関の明かりが現れ、3秒以降は停止。再スクロールでは再生しない。ページ再訪・再読込では再生する。
- CSS opacity のみ。GIF、動画、アニメーションライブラリなし。4:3全体を表示して建物と車を切り落とさない。
- `prefers-reduced-motion: reduce` は最初から元写真の夜景。JavaScript無効時は朝の静止画（reduce設定なら夜）。後続画像の読込失敗時は朝を維持。
- 小容量のWebPを事前生成し、`next/image` の `unoptimized` で直接配信するため、追加の画像変換待ちがない。全画像eager、朝のみfetchPriority high。
- 朝 960×720 / 64,552 bytes、昼 960×720 / 65,374 bytes、夜 480×360 / 11,588 bytes。合計141,514 bytes（約138.2KiB）。

## 保存ファイル

- `app/components/ShareHouseHero.js`: 読込・表示検知、画像と注記。
- `app/components/ShareHouseHero.module.css`: 3秒のクロスフェード、静止設定、画像レイアウト。
- `app/page.js`: ヒーロー画像部分のみ置換。
- `app/page.module.css`: 旧ヒーロー画像専用スタイルと拡大アニメーションを削除。
- `public/landing/share-house-morning.webp`, `share-house-day.webp`, `share-house-night.webp`: 配信用の最終画像。
- `output/hero-qa/`: ローカルの画面キャプチャ、検証スクリプト、結果JSON（gitignore対象）。

ヘッダー・フッター・CTA・`/welcome-user`・カレンダーのコードは変更していない。旧画像も削除していない。他の作業ツリーと未追跡ファイルは変更していない。

## 画像制作

imagegenスキルのbuilt-inツールを使用。元写真はユーザー指定の
`/Users/dareka/Pictures/Photos Library.photoslibrary/resources/derivatives/masters/E/E8D5D8B7-91F4-41EE-9EFB-8267B2030A4C_4_5005_c.jpeg`。
MPOとして判定されたためSharpで画素を変えずPNGへ変換して入力。夜は元写真をWebP圧縮したもの。朝・昼の生成後の縮小・圧縮にもSharpを使用。

最終昼PNG: `/Users/dareka/.codex/generated_images/01a09841-0750-7cb1-896a-e71f891de9e0/exec-2fd0081f-2a65-4db8-b908-357cab6638e7.png`

最終朝PNG: `/Users/dareka/.codex/generated_images/01a09841-0750-7cb1-896a-e71f891de9e0/exec-8a24b15a-51b6-4844-b996-0c5a5b85940b.png`

昼の最終プロンプト（入力1:元写真、入力2:初回朝生成の構図・スタイル参照）:

> Use case: lighting-weather. Image 1 is original NIGHT photograph and primary geometry/signage truth. Image 2 is morning version and alignment/style reference. Create ONE bright MIDDAY version at same 4:3 composition for CSS crossfade, clear bright blue sky and neutral daylight. Windows and entrance lights OFF with subdued natural glass reflections. Preserve exact building, roof outline, window and door coordinates and parked vehicles of image 1, use same framing and photographic appearance as image 2. Sign on building should read 平泉町志業シェアハウス as in original, never invent place names. Retain all signs in original positions. No crop, no zoom, no redesign, no extra objects or lettering. Change ONLY lighting/sky.

朝の最終プロンプト（入力:最終昼PNG）:

> Use case: lighting-weather. Edit this exact image to soft early MORNING sun. Change ONLY illumination: soft warm morning sunlight from left, paler blue sky, longer gentle shadows. Keep all pixels/geometry/composition as closely aligned as possible for crossfade: unchanged roof/building shape, cars, windows, doors, vegetation, 4:3 framing and signage. The Japanese building sign must remain exactly 平泉町志業シェアハウス. Preserve all original lettering without any edits. Indoor and entrance lights remain off. No crop, no zoom, no new objects, no redesign. Photorealistic. One image.

初回朝生成は看板文字の変化があったため配信には使用していない。

## 検証（2026-09-13）

- `npm test`: 473件成功。
- `npm run lint`: 成功、警告なし。
- `npm run build`: 成功。
- productionサーバー上でChromium・WebKit、幅1440/768/390/320pxを検証。
- 各幅で朝・昼・夜・6秒位置の停止、3枚のロード完了、横はみ出しなし、ブラウザー例外なし。
- Chromium・WebKitでreduce設定時の夜静止を確認。
- 昼画像の読込を3.5秒保留し、朝のまま待機→読込後再生→3秒後夜で停止を実時間で確認。
- `/welcome-user` と `/calendar` はHTTP 200。既存ヘッダー・フッターとCTAリンクの存在も確認。
- PC・スマートフォンの全ページキャプチャを目視確認。

## 公開前の人による確認

- 元写真が480×360のため、夜景の拡大表示にはぼけがある。高解像度の原本があれば差し替えを検討。
- 朝・昼は生成による照明再現。建物・車の配置は概ね維持しているが、看板の細字、植栽、屋根・車の輪郭は元写真と完全一致しない。施設の表記や外観として問題ないか、および昼→夜の重なりを確認。
- 3秒の速度、夜の暗さ、スマートフォン実機での見え方を確認。
- 本番公開・mainへのマージ・PR #119のマージは行わない。
