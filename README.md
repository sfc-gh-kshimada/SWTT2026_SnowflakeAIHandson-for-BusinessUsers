# 初めてのSnowflake AI 〜ビジネスユーザ編〜

SWT Tokyo 2026 のハンズオン HO1216 を、自分のアカウントで再現できるように組み直した教材です。

小売業のエリア事業責任者を演じます。Snowflake CoWork と Cortex Agent を使い、部下の報告書・顧客レビュー・売上データ・競合IR・手元の Excel を突き合わせ、最後に次期事業計画の PPTX を作ります。所要時間は約60分です。

データはすべて架空の企業・架空の人物です。

## 環境セットアップ

SWT では、Snowflake 側でビジネスユーザー向けのトライアルアカウントを複数作成し、それぞれに `setup.sql` を流しました。`setup.sql` は参加者ユーザー（`USER1`〜`USER5`）を作成します。運営がそのログイン情報を参加者に配り、参加者は `ai.snowflake.com` から CoWork にログインする形です。AI の使いすぎを防ぐため、`setup.sql` で Per-user Quota を 15クレジット/日 に設定しています。

> SWT 当日は報告書 PDF を AWS S3 に置き、外部ステージから読み込むことで手動アップロードを不要にしていました。このリポジトリ版では、内部ステージへ手動でアップロードします。

## 前提

- `ACCOUNTADMIN` を使えるアカウントであること。`COMPUTE_WH` がなければ `setup.sql` が作ります
- Enterprise Edition 以上（付録F のマスキング・行アクセスポリシーを使う場合）
- Cortex の AI 関数・Agent・CoWork が使えること。東京リージョンでは `CORTEX_ENABLED_CROSS_REGION` が必要です

## setup.sql の実行の流れ

1. `setup.sql` を **460行目まで**実行します（内部ステージ `STG_SOURCE_PDF` の作成まで）
2. ステージに報告書 PDF 4本を格納します（下記）。PDF は [out/pdf](https://github.com/sfc-gh-kshimada/SWTT2026_SnowflakeAIHandson-for-BusinessUsers/tree/main/out/pdf) にある月次業績報告です
3. `setup.sql` の **462行目以降**を実行します（約6〜10分）

PDF が4本揃っていない状態で先に進むと、チェック処理が `報告書PDFが4本揃っていない。…` というエラーで停止します。その場合は PDF を格納してから、462行目以降を再実行してください。最初から全体を再実行しても問題ありません。ステージは `IF NOT EXISTS` で作るため、格納済みの PDF は消えません。

最後の `SETUP COMPLETE` 行で件数を確認します。店舗 12 / 商品 12 / 日次実績 25,920 / 文書 132 / 報告書 4 / レビュー 約620 になっていれば完了です。

### 報告書PDFの格納

`out/pdf/` にある次の4本を格納します（競合IRのPDFは不要です）。

- `S017_月次業績報告_P042.pdf`
- `S008_月次業績報告_P042.pdf`
- `S031_月次業績報告_P042.pdf`
- `S017_月次業績報告_P057.pdf`

格納方法は次のどちらかです。

- **Snowsight**: Data › Databases › `SWT_CW_HANDSON` › `DOCUMENTS` › Stages › `STG_SOURCE_PDF` › **+ Files**
- **Snowflake CLI**:
  ```bash
  snow stage copy "out/pdf/*_月次業績報告_*.pdf" @SWT_CW_HANDSON.DOCUMENTS.STG_SOURCE_PDF
  ```

## ログイン

`ai.snowflake.com` に参加者ユーザー **`USER1`〜`USER5`** でログインします。パスワードは `setup.sql` のセクション14.2 にあります。共有する前に必ず変更してください。

- 参加者ユーザーは `ALLOWED_INTERFACES = (SNOWFLAKE_INTELLIGENCE)` で、CoWork 以外の画面には入れません
- Trial 以外のアカウントでは、初回ログイン時にMFA登録を求められます
- 実行者本人でも、ロールを `SWT_PARTICIPANT` に切り替えれば同じ見え方で試せます

## CoWork 実行の流れ

3つの Agent を用意しています。Agent1 から順に、候補の質問例を試してください。

### Agent1（`BUSINESS_DECISION_AGENT_1`）: まずはシンプルにデータ分析

質問例の1つ目から4つ目を順に試します。各店舗の店長の報告では「問題ない」とされていた横浜みなと店について、売上データなどと比較すると欠品が起きていることがわかります。最終的に、横浜みなと店のクレストリフレッシュウォーターに問題があることにたどり着きます。

### Agent2（`BUSINESS_DECISION_AGENT_2`）: 手元のファイルを加えた分析と PPTX 生成

`out/xlsx/` の Excel と `out/pdf/` の競合IRの PDF を CoWork に添付し、追加のデータ分析を行います。最後に、`out/pptx/` のブランドテンプレートを使って次期事業計画の PPTX を生成します。

### Agent3（`BUSINESS_DECISION_AGENT_3`）: 余裕があれば機能を試す

- Web search
- マスキング・行アクセスポリシー（`SWT_PARTICIPANT` では関東の107件だけが見え、PII はマスクされます）

## 作成されるオブジェクト

すべて `SWT_CW_HANDSON` データベースの配下に作成されます。

| スキーマ | オブジェクト |
|---|---|
| `CORE` | `V_PARAMS` / `DIM_STORE` / `DIM_PRODUCT` / `FACT_STORE_PRODUCT_DAY`（25,920行） |
| `DOCUMENTS` | `DOCUMENT_CORPUS`(132) / `MANAGER_REPORT`(4) / `CUSTOMER_REVIEW`(624) / Cortex Search 3本 / `STG_SOURCE_PDF` |
| `SEMANTIC` | `RETAIL_PERFORMANCE`（Semantic View） |
| `GOVERNED` | 付録F 用。`CUSTOMER_CONTACT`（架空PII 300件）/ `ROLE_REGION_MAP` / `CUSTOMER_GOVERNANCE`（Semantic View）/ マスキングポリシー4本 / 行アクセスポリシー1本 |
| `AI` | `BUSINESS_DECISION_AGENT_1` / `_2` / `_3`。ツールは6本で、Agent3 のみ Web検索とガバナンス分析を加えた8本 |
| `OPS` | Per-user Quota `AI_QUOTA_15` と除外タグ `QUOTA_EXEMPT` |

ロールは `SWT_PARTICIPANT`（参加者の見え方で、関東107件・PIIマスク）と `SWT_DATA_STEWARD`（マスク除外で、全300件）の2つです。

## 共有デモアカウントで使う場合の注意

`setup.sql` はアカウント全体に影響する変更を4つ行います。他のユーザーもいるアカウントでは、了承のうえで実行してください。

- **`ALTER ACCOUNT SET ENABLE_CORTEX_WEBSEARCH = TRUE`**: Agent3 の Web検索に必要です。検索クエリは Brave Search API を経由して Snowflake の外に出ます。顧客環境で有効化する場合は必ず事前に合意を取ってください
- **CoWork の既定オブジェクトへの Agent 追加**: 同じアカウントの他ユーザーの CoWork にも Agent が表示されます
- **Per-user Quota（日次15 AIクレジット）**: 除外タグ `STAFF` の付いていない**アカウント内の全ユーザー**が対象です。除外されるのは実行者本人だけなので、共有アカウントでは他の利用者もブロックされます。その場合は `setup.sql` のセクション14.4（2753行目〜）を実行しないでください
- **`USER1`〜`USER5` の作成**: `CREATE OR REPLACE USER` のため、同名のユーザーがいると上書きされます。事前に `SHOW USERS LIKE 'USER%';` で確認してください

## ディレクトリ

```
setup.sql  環境セットアップ（参加者ユーザー作成と Per-user Quota を含む）
out/       配布資産（報告書・競合IRのPDF / 店舗速報のXLSX / ブランドテンプレートとサンプルのPPTX）
```

資産の生成スクリプトとシナリオ設計書は含めていません。必要な場合は作成者（Keita Shimada）に連絡してください。
