# 初めてのSnowflake AI 〜ビジネスユーザ編〜（社内版）

SWT Tokyo 2026 のハンズオン HO1216 を、社内メンバーが自分のアカウントで再現できるように組み直した教材です。

小売業のエリア事業責任者を演じます。Snowflake CoWork と Cortex Agent を使い、部下の報告書・顧客レビュー・売上データ・競合IR・手元の Excel を突き合わせ、最後に次期事業計画の PPTX を作ります。所要時間は約60分です。

データはすべて架空の企業・架空の人物です。

> **社内限定。** このリポジトリを顧客や社外へ共有しないでください。

## SWT当日版との違い

| 項目 | SWT当日版 | 社内版 |
|---|---|---|
| 実行環境 | 運営が Trial を20アカウント一括展開 | 各自のデモ/Trialアカウント |
| 参加者ユーザー（USER1〜5） | 自動作成 | 自動作成（同じ定義） |
| 講師ユーザー（3名） | 自動作成 | 作らない。実行者本人が講師役 |
| Per-user Quota | 日次15クレジット | 作らない |
| 報告書PDFの置き場所 | 公開S3の外部ステージ | 内部ステージ（手動アップロード） |
| SQLファイル | 事前チェック・セットアップ・検証・撤収の4本 | `setup.sql` の1本 |

## 前提

- `ACCOUNTADMIN` を使えるアカウントであること。`COMPUTE_WH` がなければ `setup.sql` が作ります
- Enterprise Edition 以上（付録F のマスキング・行アクセスポリシーを使う場合）
- Cortex の AI 関数・Agent・CoWork が使えること。東京リージョンでは `CORTEX_ENABLED_CROSS_REGION` が必要です

## セットアップ

Snowsight のワークシートに `setup.sql` を開き、**すべて実行**します。

1. 1回目はセクション6（内部ステージの作成直後）で意図的にエラー停止します
2. 報告書PDFを4本アップロードします（下記）
3. `setup.sql` をもう一度最初から実行します。約6〜10分で完了します

最後の `SETUP COMPLETE` 行で件数を確認します。店舗 12 / 商品 12 / 日次実績 25,920 / 文書 132 / 報告書 4 / レビュー 約620 になっていれば完了です。

### 報告書PDFのアップロード

`setup.sql` を初回実行すると、内部ステージ `SWT_CW_HANDSON.DOCUMENTS.STG_SOURCE_PDF` を作成したところで次のエラーが出て停止します。

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

アップロードしたら `setup.sql` を最初から再実行します。ステージは `IF NOT EXISTS` で作るため、アップロード済みのファイルは消えません。

## ハンズオンの始め方

1. `ai.snowflake.com` に参加者ユーザー **`USER1`〜`USER5`** でログインします。パスワードは `setup.sql` セクション14.2 にあります。共有する前に必ず変更してください
   - 参加者ユーザーは `ALLOWED_INTERFACES = (SNOWFLAKE_INTELLIGENCE)` で、CoWork 以外の画面には入れません
   - Trial 以外のアカウントでは、初回ログイン時にMFA登録を求められます
   - 実行者本人でも、ロールを `SWT_PARTICIPANT` に切り替えれば同じ見え方で試せます
2. `BUSINESS_DECISION_AGENT_1`〜`_3` を選びます。定義はほぼ同じで、候補の質問だけが違います
3. 追加課題では `out/xlsx/` の Excel を CoWork にアップロードします
4. PPTX 生成の実習では、`out/pptx/` のブランドテンプレートとサンプルを参考にします

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

`setup.sql` はアカウント全体に影響する変更を3つ行います。他のユーザーもいるアカウントでは、了承のうえで実行してください。

- **`ALTER ACCOUNT SET ENABLE_CORTEX_WEBSEARCH = TRUE`**: Agent3 の Web検索に必要です。検索クエリは Brave Search API を経由して Snowflake の外に出ます。顧客環境で有効化する場合は必ず事前に合意を取ってください
- **CoWork の既定オブジェクトへの Agent 追加**: 同じアカウントの他ユーザーの CoWork にも Agent が表示されます
- **`USER1`〜`USER5` の作成**: `CREATE OR REPLACE USER` のため、同名のユーザーがいると上書きされます。事前に `SHOW USERS LIKE 'USER%';` で確認してください

## ディレクトリ

```
setup.sql  環境セットアップ（参加者ユーザー作成を含む）
out/        配布資産（報告書・競合IRのPDF / 店舗速報のXLSX / ブランドテンプレートとサンプルのPPTX）
```

資産の生成スクリプトとシナリオ設計書は含めていません。必要な場合は作成者（Keita Shimada）に連絡してください。
