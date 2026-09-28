# 初めてのSnowflake AI 〜ビジネスユーザ編〜（社内版）

SWT Tokyo 2026 のハンズオン HO1216 を、社内メンバーが自分のアカウントで再現できるように組み直した教材です。

小売業のエリア事業責任者を演じます。Snowflake CoWork と Cortex Agent を使い、部下の報告書・顧客レビュー・売上データ・競合IR・手元の Excel を突き合わせ、最後に次期事業計画の PPTX を作ります。所要時間は約60分です。

データはすべて架空の企業・架空の人物です。

> **社内限定。** このリポジトリを顧客や社外へ共有しないでください。

## SWT当日版との違い

| 項目 | SWT当日版 | 社内版 |
|---|---|---|
| 実行環境 | 運営が Trial を20アカウント一括展開 | 各自のデモ/Trialアカウント |
| 参加者・講師ユーザー | 自動作成（パスワード固定） | 作らない。実行者本人が使う |
| Per-user Quota | 日次15クレジット | 作らない |
| 報告書PDFの置き場所 | 公開S3の外部ステージ | 内部ステージ（手動アップロード） |
| リソースモニター | 自動作成 | 任意（コメントアウト） |

## 前提

- `ACCOUNTADMIN` を使えるアカウントであること
- Enterprise Edition 以上（付録F のマスキング・行アクセスポリシーを使う場合）
- Cortex の AI 関数・Agent・CoWork が使えること。東京リージョンでは `CORTEX_ENABLED_CROSS_REGION` が必要です

## セットアップ

Snowsight のワークシートで次の順に実行します。

| 順 | ファイル | 内容 | 所要 |
|---|---|---|---|
| 1 | `sql/00_preflight.sql` | 前提機能のチェック。`COMPUTE_WH` がなければ作成します | 約1分 |
| 2 | `sql/01_setup.sql` | 環境の作成。**初回はセクション6で意図的に停止します** | 約6〜10分 |
| 3 | 報告書PDFのアップロード | 下記参照 | 約1分 |
| 4 | `sql/01_setup.sql` | 最初から再実行します | 約6〜10分 |
| 5 | `sql/02_verify.sql` | 検証（PASS/FAIL で判定） | 約3分 |

### 報告書PDFのアップロード

`01_setup.sql` を初回実行すると、内部ステージ `SWT_CW_HANDSON.DOCUMENTS.STG_SOURCE_PDF` を作成したところで次のエラーが出て停止します。

```
報告書PDFが4本揃っていない。…
```

`out/pdf/` にある次の4本をアップロードしてください（競合IRのPDFは不要です）。

- `S017_月次業績報告_P042.pdf`
- `S008_月次業績報告_P042.pdf`
- `S031_月次業績報告_P042.pdf`
- `S017_月次業績報告_P057.pdf`

アップロード方法は次のどちらかです。

- **Snowsight**: Data › Databases › `SWT_CW_HANDSON` › `DOCUMENTS` › Stages › `STG_SOURCE_PDF` › **+ Files**
- **Snowflake CLI**:
  ```bash
  snow stage copy "out/pdf/*_月次業績報告_*.pdf" @SWT_CW_HANDSON.DOCUMENTS.STG_SOURCE_PDF
  ```

アップロードしたら `01_setup.sql` を最初から再実行します。ステージは `IF NOT EXISTS` で作るため、アップロード済みのファイルは消えません。

## ハンズオンの始め方

1. `ai.snowflake.com` を開き、画面右上でロールを **`SWT_PARTICIPANT`** に切り替えます。`01_setup.sql` がこのロールを実行者に付与しています。参加者と同じ権限と見え方になります
2. `BUSINESS_DECISION_AGENT_1`〜`_3` を選びます。定義はほぼ同じで、候補の質問だけが違います
3. 追加課題では `out/xlsx/` の Excel を CoWork にアップロードします
4. PPTX 生成の実習では、`out/pptx/` のブランドテンプレートとサンプルを参考にします

`out/pptx/投影スライド_初めてのSnowflakeAI_ビジネスユーザ編.pptx` は、SWT当日に投影した進行スライドです。

## 作成されるオブジェクト

すべて `SWT_CW_HANDSON` データベースの配下に作成されます。

| スキーマ | オブジェクト |
|---|---|
| `CORE` | `V_PARAMS` / `DIM_STORE` / `DIM_PRODUCT` / `FACT_STORE_PRODUCT_DAY`（25,920行） |
| `DOCUMENTS` | `DOCUMENT_CORPUS`(132) / `MANAGER_REPORT`(4) / `CUSTOMER_REVIEW`(624) / Cortex Search 3本 / `STG_SOURCE_PDF` |
| `SEMANTIC` | `RETAIL_PERFORMANCE`（Semantic View） |
| `GOVERNED` | 付録F 用。`CUSTOMER_CONTACT`（架空PII 300件）/ `ROLE_REGION_MAP` / `CUSTOMER_GOVERNANCE`（Semantic View）/ マスキングポリシー4本 / 行アクセスポリシー1本 |
| `AI` | `BUSINESS_DECISION_AGENT_1` / `_2` / `_3`。ツールは6本で、Agent3 のみ Web検索とガバナンス分析を加えた8本 |

ロールは `SWT_PARTICIPANT`（参加者の見え方で、関東107件・PIIマスク）と `SWT_DATA_STEWARD`（マスク除外で、全300件）の2つです。

## 共有デモアカウントで使う場合の注意

`01_setup.sql` はアカウント全体に影響する設定を2つ変えます。`00_preflight.sql` の `[5]` で、他のユーザーがいれば WARN を出します。

- **`ALTER ACCOUNT SET ENABLE_CORTEX_WEBSEARCH = TRUE`**: Agent3 の Web検索に必要です。検索クエリは Brave Search API を経由して Snowflake の外に出ます。顧客環境で有効化する場合は必ず事前に合意を取ってください
- **CoWork の既定オブジェクトへの Agent 追加**: 同じアカウントの他ユーザーの CoWork にも Agent が表示されます

## 撤収

`sql/04_teardown.sql` を実行すると、CoWork から Agent を外し、ウェアハウスを停止します。ロールと `DROP DATABASE` は取り消せないため、コメントアウトしてあります。中身を確認してから外してください。

## 設計上の注意

- **日付は `CURRENT_DATE` 基準です。** いつ実行しても「直近90日」が成立します。ただし報告書PDFの本文に書かれた報告日は、PDFを生成した時点の絶対日付です
- **報告書の本文は `AI_PARSE_DOCUMENT` がPDFから読み取ります。** 日本語は公式のサポート言語に含まれていません。`02_verify.sql` の `[12][13]` で読み取り品質を確認してください。退避手順は `01_setup.sql` のセクション7末尾にあります
- **Semantic View の権限は `SELECT` です。** `GRANT USAGE ON SEMANTIC VIEW` は失敗します（2026-09-08 実測）
- **`ALTER AGENT` はありません。** Agent は `CREATE OR REPLACE` で作り直します。Snowsight で直した内容は `01_setup.sql` に書き戻さないと、次のセットアップで消えます

## ディレクトリ

```
sql/   事前チェック・セットアップ・検証・撤収
out/   配布資産（報告書・競合IRのPDF / 店舗速報のXLSX / ブランドテンプレートとサンプルのPPTX）
```

資産の生成スクリプトとシナリオ設計書は含めていません。必要な場合は作成者（Keita Shimada）に連絡してください。
