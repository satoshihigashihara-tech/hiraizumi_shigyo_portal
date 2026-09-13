# シェアハウスの朝 → 昼 → 夜

PR #119 (`codex/landing-page`, `2e2277e`) を基準に、`codex/hero-day-night` で実装。

## 動作と配信

- LPヒーローの画像を横幅いっぱいに拡大し、空の部分に「平泉で始める、その一歩を。手続きで止めない。」を配置。CTAは画像下に維持。
- 朝→昼→夜→朝を5周だけ再生。周回時間は1.8、1.8、2.4、3.3、6.3秒、合計15.6秒。前半は速く、最後の夜→朝は3秒かけて減速感のあるクロスフェードで朝に戻り、停止する。
- CSSの単一有限タイムライン（各画像1回・forwards）。最後まで再生すると操作ボタンは「再生終了」になる。一時停止・再生に対応。
- 全画像のdecodeと25%以上の画面内表示を待って開始。読込失敗時は朝の静止画を維持。
- prefers-reduced-motionは夜静止。動作ボタンを非表示にする。
- 夜は生成済みの朝・昼だけを参照。元写真・旧夜画像は再生成に使用していない。CSSによる位置・横幅補正なし。
- PCは16:9、スマートフォンは4:3。全3枚に同じobject-fitとobject-positionを適用して構図を揃える。
- 3枚のWebPは合計162,544 bytes（約158.7KiB）。追加の動画・画像再生成・アニメーションライブラリなし。

## 保存ファイル

- `app/components/ShareHouseHero.js`: 読込・表示検知、画像と注記。
- `app/components/ShareHouseHero.module.css`: 5周で減速終了するクロスフェード、静止設定、画像レイアウト。
- `app/page.js`: 全幅ヒーロー、空のコピー、画像下のCTAを配置。
- `app/page.module.css`: ヒーローの画像上コピーとレスポンシブレイアウト。
- `public/landing/share-house-morning.webp`, `share-house-day.webp`, `share-house-night.webp`: 配信用の最終画像。
- `output/hero-qa/`: ローカルの画面キャプチャ、検証スクリプト、結果JSON（gitignore対象）。
- `output/hero-qa/animation.html`: 3枚を埋め込んだ単体再生用アニメーション。一時停止・再生ボタン付き。LPと同じCSSを使用（gitignore対象）。

ヘッダー・フッター・CTA・`/welcome-user`・カレンダーのコードは変更していない。旧画像も削除していない。他の作業ツリーと未追跡ファイルは変更していない。

## 画像制作

imagegenスキルのbuilt-inツールを使用。元写真はユーザー指定の
`/Users/dareka/Pictures/Photos Library.photoslibrary/resources/derivatives/masters/E/E8D5D8B7-91F4-41EE-9EFB-8267B2030A4C_4_5005_c.jpeg`。
MPOとして判定されたためSharpで画素を変えずPNGへ変換して入力。朝・昼・夜すべてbuilt-in imagegenで生成。最新の夜は生成済みの昼を編集対象、朝を補助参照として生成した。元写真と旧夜画像は参照していない。夕方の独立画像は保存されておらず、遷移途中の表示に相当する。生成後の縮小・圧縮にはSharpを使用。

最終昼PNG: `/Users/dareka/.codex/generated_images/01a09841-0750-7cb1-896a-e71f891de9e0/exec-2fd0081f-2a65-4db8-b908-357cab6638e7.png`

最終朝PNG: `/Users/dareka/.codex/generated_images/01a09841-0750-7cb1-896a-e71f891de9e0/exec-8a24b15a-51b6-4844-b996-0c5a5b85940b.png`

昼の最終プロンプト（入力1:元写真、入力2:初回朝生成の構図・スタイル参照）:

> Use case: lighting-weather. Image 1 is original NIGHT photograph and primary geometry/signage truth. Image 2 is morning version and alignment/style reference. Create ONE bright MIDDAY version at same 4:3 composition for CSS crossfade, clear bright blue sky and neutral daylight. Windows and entrance lights OFF with subdued natural glass reflections. Preserve exact building, roof outline, window and door coordinates and parked vehicles of image 1, use same framing and photographic appearance as image 2. Sign on building should read 平泉町志業シェアハウス as in original, never invent place names. Retain all signs in original positions. No crop, no zoom, no redesign, no extra objects or lettering. Change ONLY lighting/sky.

朝の最終プロンプト（入力:最終昼PNG）:

> Use case: lighting-weather. Edit this exact image to soft early MORNING sun. Change ONLY illumination: soft warm morning sunlight from left, paler blue sky, longer gentle shadows. Keep all pixels/geometry/composition as closely aligned as possible for crossfade: unchanged roof/building shape, cars, windows, doors, vegetation, 4:3 framing and signage. The Japanese building sign must remain exactly 平泉町志業シェアハウス. Preserve all original lettering without any edits. Indoor and entrance lights remain off. No crop, no zoom, no new objects, no redesign. Photorealistic. One image.

初回朝生成は看板文字の変化があったため配信には使用していない。

最終夜PNG: `/Users/dareka/.codex/generated_images/01a09841-0750-7cb1-896a-e71f891de9e0/exec-0d0556ef-f048-4cdb-8a93-bf57b4d81df6.png`

夜の最終プロンプト（入力1:最終昼WebP、入力2:最終朝WebP）:

> Use case: lighting-weather. EDIT TARGET: image 1, the generated DAY frame. Image 2 is the generated MORNING frame, supporting style/alignment reference only. Use ONLY these two generated images. Create one NIGHT frame of exactly this same locked-off shot. This is a strict RELIGHT, not a recreation. All structural edges must stay at the exact same normalized pixel coordinates as image 1: roof apex around y=0.563, left eave x=0.153 y=0.605, right eave x=0.829 y=0.604, ground tire contact y=0.900. Maintain all roof lines, windows, entrance, cars and wheels, signs, neighboring buildings, grass and utility wires without shifting, scaling, warping or redrawing geometry. Preserve full 4:3 framing and lens perspective. Change ONLY daylight illumination into natural nighttime: deep navy sky, dim but legible facade, warm indoor light in the central upstairs window, entrance and ground-floor right windows, other windows mostly dark. Preserve EXACT lettering and all objects. Keep same image style and sharpness as provided frames. No reference to any original source photo or previous night image; derive night entirely from this supplied day frame. No crop, zoom, camera motion, perspective change, new objects, moon, stars or extra fixtures. Output one image, not a collage.

## 検証（2026-09-13）

- npm test、lint、production build。
- Chromium・WebKit、幅1440/768/390/320pxで5周分の昼夜、15.6秒以降から30秒まで朝の静止、終盤の遅いフェード、横はみ出しなし、コピーが屋根より上の空に収まることを検証。
- 一時停止・再開、reduce時の夜静止を確認。
- PC・スマートフォンの全ページキャプチャを目視確認。
- ヘッダー、フッター、welcome-user、カレンダーのソースは未変更。カレンダー実データはローカルSupabase設定不足のため未検証。
- output/hero-qa/check-five.cjs と five-results.json に最新の検証内容を保存。

## 公開前の人による確認

- 朝・昼・夜はすべて生成による照明再現。建物・車の配置は概ね維持しているが、看板の細字、植栽、屋根・車の輪郭は元写真と完全一致しない。施設の表記や外観として問題ないか、および昼→夜の重なりを確認。
- 5周の速度と終盤の減速、夜の暗さ、スマートフォン実機での見え方を確認。
- 本番公開・mainへのマージ・PR #119のマージは行わない。
