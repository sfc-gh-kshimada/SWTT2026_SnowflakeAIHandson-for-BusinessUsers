-- =============================================================================
-- SWT Tokyo HO1216 / 初めてのSnowflake AI 〜ビジネスユーザ編〜
-- 01_setup.sql : ハンズオン環境を作成する
--
-- 実行者   : ACCOUNTADMIN
-- 前提     : 00_preflight.sql が全てPASSしていること
--            報告書PDF 4本を内部ステージへアップロードすること
--            （セクション6で止まるので、README の手順でアップロードして
--              このファイルを最初から再実行する。既存オブジェクトは作り直される）
--
-- 【社内版】各自のデモ/Trialアカウントで ACCOUNTADMIN が1人で実行する前提。
--   SWT当日版にあった参加者・講師ユーザーの作成、Per-user Quota、
--   公開S3の外部ステージは削除している。
-- 実行時間 : 約6〜10分（Cortex Search 3本の初期化とPDF4本の解析を含む）
--
-- 作成物
--   SWT_CW_HANDSON.CORE       : 店舗、商品、店舗商品日次実績
--   SWT_CW_HANDSON.DOCUMENTS  : 社内文書コーパス、部下報告書、顧客レビュー、
--                               Cortex Search 3本、報告書PDFの外部ステージ
--   SWT_CW_HANDSON.SEMANTIC   : Semantic View
--   SWT_CW_HANDSON.AI         : Cortex Agent
--
-- 設計方針
--   1. 日付は全てCURRENT_DATE基準。実施日がいつでも「直近90日」が成立する。
--      例外は報告書PDFの本文に焼き込まれた報告日で、これはPDF生成時点の
--      絶対日付になる。イベント直前に資産を再生成すること。
--   2. データ量は 12店舗 × 12商品 × 180日 = 25,920行。
--      物語の成立に必要な最小規模。参加者のXSウェアハウスで数十秒で完了する。
--   3. 参加者は自分専用のアカウントでACCOUNTADMINとして実行する。
--      使い捨て環境のため、最小権限ロールは作らない。手順を減らし失敗を防ぐ。
--      顧客のPoC環境では必ず専用ロールと最小権限で構成すること。
--   4. 部下報告書と顧客レビューは、既存の DOCUMENT_CORPUS に混ぜず
--      独立したテーブル + 独立したCortex Searchにする。
--      理由: 既存コーパスのDOC-F005（エリアレポート）が
--      主役ケースの真因をすでに書いており、実習1の「報告書と数字のギャップを
--      自分で見つける」体験を先に壊してしまう。
--      報告書を別ツールに切り出すことで、実習1の探索範囲を報告書だけに限定できる。
--   5. 報告書の本文は AI_PARSE_DOCUMENT で実PDFから文字起こしする。
--      PDFは内部ステージから読む。実行者が out/pdf/ の4本を事前にアップロードする。
--      理由: 非構造化データが実際にどう構造化されるかを教材として見せる価値が、
--      解析失敗のリスクを上回ると判断した。
--
--      引き受けたリスク: 日本語は AI_PARSE_DOCUMENT の公式サポート言語一覧に
--      含まれていない。2026-09-03時点の実測では4本すべて本文を完全に取得でき、
--      キーフレーズ（計画比98パーセントで着地 / 影響は軽微 / 欠品 /
--      納品数量 / 在庫）も検出できている。品質劣化を検知するため
--      sql/02_verify.sql のアサーションを当日まで回すこと。
--      既知の誤読: LAYOUTモードは文書番号を RPT-5017-P042 と読む（S→5）。
--      REPORT_ID はメタデータ側から与えるため実害はない。
--
--      退避手段: 旧方式の本文リテラルはセクション7末尾にコメントアウトで
--      残してある。復帰させれば解析なしの構成に即戻せる。
--
-- セクション順の制約
--   セクション6（外部ステージ）はセクション7（報告書テーブル）の前提。
--   Cortex Search 3本は元テーブルの後。Agentは全ツールの後。
--   並べ替えるときはこの依存を壊さないこと。
-- =============================================================================

USE ROLE ACCOUNTADMIN;

-- Agent の tool_resources が COMPUTE_WH を前提にしている。無ければ作る。
CREATE WAREHOUSE IF NOT EXISTS COMPUTE_WH
  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;
USE WAREHOUSE COMPUTE_WH;

CREATE DATABASE IF NOT EXISTS SWT_CW_HANDSON
  COMMENT = 'SWT Tokyo HO1216 ハンズオン用。イベント後は削除してよい';

CREATE SCHEMA IF NOT EXISTS SWT_CW_HANDSON.CORE;
CREATE SCHEMA IF NOT EXISTS SWT_CW_HANDSON.DOCUMENTS;
CREATE SCHEMA IF NOT EXISTS SWT_CW_HANDSON.SEMANTIC;
CREATE SCHEMA IF NOT EXISTS SWT_CW_HANDSON.AI;

USE DATABASE SWT_CW_HANDSON;

-- =============================================================================
-- 1. 期間パラメータ
--    以降のすべてのテーブルがこのビューを参照する。
--    実行日が変わっても整合性が保たれる。
-- =============================================================================
CREATE OR REPLACE VIEW SWT_CW_HANDSON.CORE.V_PARAMS AS
SELECT
  DATEADD(day, -180, CURRENT_DATE()) AS data_start,   -- データ開始日
  DATEADD(day,   -1, CURRENT_DATE()) AS data_end,     -- データ最終日（前日）
  DATEADD(day,  -45, CURRENT_DATE()) AS promo_start,  -- 販促期間の開始
  DATEADD(day,  -18, CURRENT_DATE()) AS promo_end;    -- 販促期間の終了


-- =============================================================================
-- 2. 店舗マスタ（12店舗）
--    S008 東京ベイ店、S017 横浜みなと店、S031 名古屋ささしま店は
--    社内文書から参照されるため、IDを変更してはいけない。
-- =============================================================================
CREATE OR REPLACE TABLE SWT_CW_HANDSON.CORE.DIM_STORE AS
SELECT * FROM VALUES
  ('S002', '札幌すすきの店',     '北海道・東北', '都市型',  920),
  ('S005', '仙台一番町店',       '北海道・東北', '郊外型', 1480),
  ('S008', '東京ベイ店',         '関東',         '都市型', 1120),
  ('S011', 'さいたま新都心店',   '関東',         '郊外型', 1650),
  ('S014', '千葉幕張店',         '関東',         '郊外型', 1580),
  ('S017', '横浜みなと店',       '関東',         '都市型',  980),
  ('S023', '静岡呉服町店',       '中部',         '小型',    520),
  ('S031', '名古屋ささしま店',   '中部',         '都市型', 1240),
  ('S036', '大阪なんば店',       '関西',         '都市型', 1080),
  ('S041', '神戸三宮店',         '関西',         '郊外型', 1390),
  ('S048', '広島紙屋町店',       '中国・四国',   '小型',    610),
  ('S055', '福岡天神店',         '九州',         '都市型', 1050)
AS v(store_id, store_name, region_name, store_format, floor_area_sqm);


-- =============================================================================
-- 3. 商品マスタ（12商品）
--    P042 クレストリフレッシュウォーター、P057 リヴェルタ冷凍パスタは
--    社内文書から参照されるため、IDを変更してはいけない。
-- =============================================================================
CREATE OR REPLACE TABLE SWT_CW_HANDSON.CORE.DIM_PRODUCT AS
SELECT * FROM VALUES
  ('P003', 'クレスト天然水スパークリング',     '飲料',       '清涼飲料', 'SUP006', 320, 195),
  ('P017', 'リヴェルタ麦茶',                 '飲料',       '清涼飲料', 'SUP002', 280, 165),
  ('P021', 'リヴェルタ和風だしパック',       '加工食品',   'レトルト', 'SUP003', 540, 340),
  ('P028', 'クレストポテトチップス',           '菓子',       'スナック', 'SUP004', 210, 128),
  ('P031', 'クレストケアシート',               '日用品',     '家庭用品', 'SUP005', 620, 395),
  ('P035', 'リヴェルタ厚手キッチンタオル',   '日用品',     '家庭用品', 'SUP005', 450, 285),
  ('P042', 'クレストリフレッシュウォーター',   '飲料',       '清涼飲料', 'SUP006', 480, 300),
  ('P049', 'クレスト冷凍唐揚げ',               '冷凍食品',   '調理食品', 'SUP009', 580, 390),
  ('P052', 'リヴェルタ冷凍うどん',           '冷凍食品',   '調理食品', 'SUP009', 350, 225),
  ('P057', 'リヴェルタ冷凍パスタ',           '冷凍食品',   '調理食品', 'SUP009', 690, 470),
  ('P063', 'クレストビタミンドリンク',         'ヘルスケア', 'セルフケア','SUP011', 760, 460),
  ('P068', 'リヴェルタ入浴タブレット',       'ヘルスケア', 'セルフケア','SUP011', 890, 545)
AS v(product_id, product_name, category_name, subcategory_name, supplier_id,
     list_price_yen, unit_cost_yen);


-- =============================================================================
-- 4. 店舗商品日次実績（25,920行）
--
--    埋め込まれた4つのケース（販促期間 = 直近45日前〜18日前）
--
--    ケース                 店舗 商品  需要  供給  値引  返品  意図
--    FOCAL_PROMO_SUPPLY     S017 P042 ×1.55 0.70  12%  8.5%  主役。複合的な問題
--    CMP_HEALTHY_PROMO      S008 P042 ×1.40 1.00  10%  2.0%  同じ販促の成功例
--    CMP_SUPPLY_ONLY        S031 P042 ×1.00 0.70   3%  2.0%  供給問題のみ
--    CMP_MARGIN_ONLY        S017 P057 ×1.10 1.00  18%  2.0%  値引きによる粗利低下のみ
--
--    売上目標は販促の上振れを含まない素の計画値。
--    そのためS017/P042は「売上は計画どおりに見えるが、欠品と返品と粗利が悪い」
--    という状態になり、売上だけを見ていると異常に気づけない。
-- =============================================================================
CREATE OR REPLACE TABLE SWT_CW_HANDSON.CORE.FACT_STORE_PRODUCT_DAY AS
WITH seq AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) - 1 AS n
  FROM TABLE(GENERATOR(ROWCOUNT => 180))
),
dates AS (
  SELECT DATEADD(day, s.n, p.data_start) AS sales_date, p.promo_start, p.promo_end
  FROM seq s
  CROSS JOIN SWT_CW_HANDSON.CORE.V_PARAMS p
),
grid AS (
  SELECT
    d.sales_date,
    st.store_id, st.store_name, st.region_name, st.store_format,
    pr.product_id, pr.product_name, pr.category_name, pr.subcategory_name,
    pr.supplier_id, pr.list_price_yen, pr.unit_cost_yen,
    IFF(d.sales_date BETWEEN d.promo_start AND d.promo_end,
      CASE
        WHEN st.store_id = 'S017' AND pr.product_id = 'P042' THEN 'FOCAL_PROMO_SUPPLY'
        WHEN st.store_id = 'S008' AND pr.product_id = 'P042' THEN 'CMP_HEALTHY_PROMO'
        WHEN st.store_id = 'S031' AND pr.product_id = 'P042' THEN 'CMP_SUPPLY_ONLY'
        WHEN st.store_id = 'S017' AND pr.product_id = 'P057' THEN 'CMP_MARGIN_ONLY'
      END,
      NULL
    ) AS case_id,
    -- 店舗商品ごとに固定の基準販売数量
    8 + MOD(BITAND(HASH(st.store_id, pr.product_id, 'BASE_V2'), 9223372036854775807), 22)
      AS base_units,
    -- 曜日係数
    CASE DAYOFWEEKISO(d.sales_date)
      WHEN 1 THEN 0.90 WHEN 2 THEN 0.92 WHEN 3 THEN 0.96
      WHEN 4 THEN 1.00 WHEN 5 THEN 1.10 WHEN 6 THEN 1.30 ELSE 1.22
    END AS weekday_factor,
    -- 季節係数
    CASE
      WHEN pr.category_name = '飲料'       AND MONTH(d.sales_date) IN (7, 8) THEN 1.35
      WHEN pr.category_name = '冷凍食品'   AND MONTH(d.sales_date) = 12      THEN 1.25
      WHEN pr.category_name = 'ヘルスケア' AND MONTH(d.sales_date) IN (1, 2) THEN 1.18
      ELSE 1.00
    END AS season_factor,
    -- 日次のばらつき
    0.85 + MOD(BITAND(HASH(st.store_id, pr.product_id, d.sales_date, 'NOISE_V2'),
                      9223372036854775807), 3001) / 10000.0 AS noise_factor
  FROM dates d
  CROSS JOIN SWT_CW_HANDSON.CORE.DIM_STORE st
  CROSS JOIN SWT_CW_HANDSON.CORE.DIM_PRODUCT pr
),
factors AS (
  SELECT
    *,
    -- 需要の上振れ倍率
    CASE case_id
      WHEN 'FOCAL_PROMO_SUPPLY' THEN 1.55
      WHEN 'CMP_HEALTHY_PROMO'  THEN 1.40
      WHEN 'CMP_MARGIN_ONLY'    THEN 1.10
      ELSE 1.00
    END AS demand_multiplier,
    -- 供給制約。需要のうち何割を販売できたか
    CASE
      WHEN case_id IN ('FOCAL_PROMO_SUPPLY', 'CMP_SUPPLY_ONLY')
           AND DAYOFWEEKISO(sales_date) <= 5 THEN 0.70
      WHEN case_id = 'FOCAL_PROMO_SUPPLY'    THEN 0.92
      ELSE 1.00
    END AS supply_ratio,
    -- 値引率
    CASE case_id
      WHEN 'FOCAL_PROMO_SUPPLY' THEN 0.12
      WHEN 'CMP_HEALTHY_PROMO'  THEN 0.10
      WHEN 'CMP_SUPPLY_ONLY'    THEN 0.03
      WHEN 'CMP_MARGIN_ONLY'    THEN 0.18
      ELSE MOD(BITAND(HASH(store_id, product_id, sales_date, 'DISCOUNT_V2'),
                      9223372036854775807), 401) / 10000.0
    END AS discount_rate,
    -- 返品率
    CASE case_id
      WHEN 'FOCAL_PROMO_SUPPLY' THEN 0.085
      WHEN 'CMP_HEALTHY_PROMO'  THEN 0.020
      WHEN 'CMP_SUPPLY_ONLY'    THEN 0.020
      WHEN 'CMP_MARGIN_ONLY'    THEN 0.020
      ELSE 0.008 + MOD(BITAND(HASH(store_id, product_id, sales_date, 'RETURN_V2'),
                              9223372036854775807), 121) / 10000.0
    END AS return_rate
  FROM grid
),
units AS (
  SELECT
    *,
    GREATEST(1, ROUND(base_units * weekday_factor * season_factor
                      * noise_factor * demand_multiplier))          AS demand_units,
    -- 売上目標は販促の上振れを含まない素の計画値
    ROUND(base_units * weekday_factor * season_factor
          * list_price_yen * (1 - 0.03), 2)                          AS target_net_sales_yen
  FROM factors
),
sold AS (
  SELECT
    *,
    LEAST(demand_units, GREATEST(0, FLOOR(demand_units * supply_ratio))) AS sold_units
  FROM units
),
returns AS (
  SELECT
    *,
    LEAST(
      sold_units,
      FLOOR(sold_units * return_rate)
      + IFF(MOD(BITAND(HASH(store_id, product_id, sales_date, 'RET_ROUND_V2'),
                       9223372036854775807), 10000)
            < (sold_units * return_rate - FLOOR(sold_units * return_rate)) * 10000, 1, 0)
    ) AS returned_units
  FROM sold
)
SELECT
  sales_date,
  store_id,
  store_name,
  region_name,
  store_format,
  product_id,
  product_name,
  category_name,
  subcategory_name,
  supplier_id,
  case_id,
  demand_units::NUMBER(12,0)                                        AS demand_units,
  sold_units::NUMBER(12,0)                                          AS sold_units,
  returned_units::NUMBER(12,0)                                      AS returned_units,
  ROUND(sold_units * list_price_yen, 2)::NUMBER(18,2)               AS list_sales_yen,
  ROUND(sold_units * list_price_yen * discount_rate, 2)::NUMBER(18,2) AS discount_yen,
  ROUND(returned_units * list_price_yen * (1 - discount_rate), 2)::NUMBER(18,2) AS return_yen,
  (
    ROUND(sold_units * list_price_yen, 2)
    - ROUND(sold_units * list_price_yen * discount_rate, 2)
    - ROUND(returned_units * list_price_yen * (1 - discount_rate), 2)
  )::NUMBER(18,2)                                                   AS net_sales_yen,
  ROUND((sold_units - returned_units) * unit_cost_yen, 2)::NUMBER(18,2) AS cogs_yen,
  target_net_sales_yen::NUMBER(18,2)                                AS target_net_sales_yen,
  -- 販売できなかった需要の割合を1日1440分に換算した欠品時間
  IFF(demand_units <= sold_units, 0,
      LEAST(1440, ROUND(1440 * (demand_units - sold_units) / NULLIF(demand_units, 0)))
  )::NUMBER(8,0)                                                    AS stockout_minutes
FROM returns;

ALTER TABLE SWT_CW_HANDSON.CORE.FACT_STORE_PRODUCT_DAY SET CHANGE_TRACKING = TRUE;


-- =============================================================================
-- 5. 社内文書コーパス（132件）
--
--    DOC-F001〜F008 : 主役ケースの原因、比較、反証
--    DOC-C001〜C002 : 別ケースとの切り分け材料
--    DOC-P001〜P002 : 業務ポリシー
--    DOC-G0001〜    : 120件のノイズ文書。検索を現実的な難易度にする
--
--    文書日付はすべて販促開始日からの相対日数で生成する。
--    本文に絶対的な月表記を書かないこと。データ日付とずれる。
-- =============================================================================
CREATE OR REPLACE TABLE SWT_CW_HANDSON.DOCUMENTS.DOCUMENT_CORPUS AS
WITH curated AS (
  SELECT
    v.document_id,
    DATEADD(day, v.day_offset, p.promo_start)::DATE AS document_date,
    v.document_type, v.title, v.body, v.author_role,
    v.region_name, v.store_id, v.product_id, v.supplier_id, v.case_id,
    '社内限定' AS confidentiality,
    v.source_system
  FROM (VALUES
    ('DOC-F001', 4, '店舗日報', '横浜みなと店 P042欠品状況',
     '午後3時ごろからクレストリフレッシュウォーターの棚が空になる時間が増えた。バックヤード在庫も残っておらず、夕方の補充時点で販売を再開できなかった。先週までは平日中に売り切れる商品ではなかったが、今週は若い来店客から売り場を尋ねられることが多い。次回納品は予定どおりとの回答だったが、現在の数量では週末まで持たない見込み。',
     '店長', '関東', 'S017', 'P042', 'SUP006', 'FOCAL_PROMO_SUPPLY', '店舗運営ポータル'),

    ('DOC-F002', 2, '販促担当メモ', '地域SNS施策の公開前倒し',
     '地域向けSNS企画の投稿が予定より二日早く公開された。投稿後、横浜みなと店ではクレストリフレッシュウォーターの指名買いが急増している。店舗への正式な販促連絡は公開後になったため、初回の発注数量には上振れ分が反映されていない。東京ベイ店では事前に投稿予定を共有しており、追加発注を実施済み。',
     '販促担当', '関東', 'S017', 'P042', 'SUP006', 'FOCAL_PROMO_SUPPLY', '販促管理'),

    ('DOC-F003', 9, '仕入先通知', 'P042外装状態に関する連絡',
     'クレストリフレッシュウォーターについて、直近の出荷分の一部で外装箱のつぶれが確認された。商品本体の品質には影響しないが、店頭陳列時にパッケージの変形が目立つ場合がある。対象ロットは通常品として販売可能であるものの、返品または交換を希望する店舗は写真を添えて申請してほしい。',
     '仕入先窓口', NULL, NULL, 'P042', 'SUP006', 'FOCAL_PROMO_SUPPLY', '調達ポータル'),

    ('DOC-F004', 16, '顧客の声サマリー', '横浜みなと店 P042問い合わせ分析',
     'クレストリフレッシュウォーターに関する問い合わせは直近2週間で18件あった。内訳は「夕方に売り切れていた」が11件、「箱がへこんでいた」が5件、「表示価格と期待していた割引が違った」が2件。味や商品内容への否定的な意見は確認されていない。欠品と外装状態への不満が中心となっている。',
     'VOC分析担当', '関東', 'S017', 'P042', 'SUP006', 'FOCAL_PROMO_SUPPLY', 'お客様相談室'),

    ('DOC-F005', 22, 'エリアレポート', '関東エリア P042レビュー',
     'クレストリフレッシュウォーターは売上数量だけを見ると計画を上回っているが、欠品時間と返品が同時に増えている。追加値引きで販売を維持しているため、売上の伸びほど粗利は改善していない。SNS施策の継続可否を判断する前に、納品数量、外装不良ロット、店頭値引きの運用を分けて確認する必要がある。',
     'エリアマネージャー', '関東', 'S017', 'P042', 'SUP006', 'FOCAL_PROMO_SUPPLY', 'エリア会議'),

    ('DOC-F006', 7, '過去対応事例', '東京ベイ店 P042事前増便',
     '東京ベイ店ではSNS公開前に通常比1.4倍の需要を想定し、初回納品を増やした。公開後に需要は想定どおり上昇したが、欠品は発生していない。外装不良が疑われる商品は入荷時に分離し、売り場へ出さなかったため、返品率も通常範囲内だった。',
     '業務改善担当', '関東', 'S008', 'P042', 'SUP006', 'CMP_HEALTHY_PROMO', 'ナレッジベース'),

    ('DOC-F007', 11, '店舗引継ぎメモ', '横浜みなと店 シフト状況',
     '対象期間のレジおよび品出しシフト充足率は計画の98パーセントで、近隣店舗と同程度だった。夕方の売り場確認では人員不足よりもバックヤード在庫不足が主な制約となっていた。人手不足が欠品の主因という見方は、勤務実績とは一致しない。',
     '副店長', '関東', 'S017', 'P042', NULL, 'FOCAL_PROMO_SUPPLY', '店舗運営ポータル'),

    ('DOC-F008', 18, '価格レビュー', 'P042価格と購入率の確認',
     '価格変更の前後を比較したところ、表示価格のみを理由とする購入率の差は小さかった。顧客コメントでも価格への不満は少数で、欠品と外装状態への言及が多数を占めた。追加値引きは返品抑制に寄与した証拠がなく、粗利を押し下げた可能性がある。',
     '価格戦略担当', '関東', 'S017', 'P042', NULL, 'FOCAL_PROMO_SUPPLY', '価格管理'),

    ('DOC-C001', 5, '店舗日報', '名古屋ささしま店 P042入荷不足',
     '一部平日にP042の入荷数量が通常を下回り、短時間の欠品が発生した。販促による需要上振れは見られず、返品や外装不良の報告もない。次回納品から通常数量へ戻る予定。',
     '店長', '中部', 'S031', 'P042', 'SUP006', 'CMP_SUPPLY_ONLY', '店舗運営ポータル'),

    ('DOC-C002', 15, '粗利レビュー', '横浜みなと店 P057値引き状況',
     'リヴェルタ冷凍パスタは競合対抗値引きを継続した結果、販売数量は微増したが粗利率が低下した。在庫と納品には問題がなく、P042の欠品問題とは分けて判断する必要がある。',
     'カテゴリーマネージャー', '関東', 'S017', 'P057', 'SUP009', 'CMP_MARGIN_ONLY', '商品会議'),

    ('DOC-P001', -47, '業務ポリシー', '販促需要増加時の追加発注ルール',
     '需要が通常比20パーセント以上増える見込みの販促では、公開日の5営業日前までに対象店舗へ連絡し、在庫責任者が追加発注量を承認する。公開日が変更された場合は、販促担当が同日中に店舗と調達へ変更通知を送る。',
     '業務統括', NULL, NULL, NULL, NULL, NULL, '業務規程'),

    ('DOC-P002', -47, '業務ポリシー', '外装不良商品の店頭運用',
     '商品本体に問題がなくても外装変形が顧客体験を損なう場合は、入荷時に対象ロットを分離する。値引き販売を行う場合はカテゴリーマネージャーの承認を得て、欠品対策と返品対策を混同しない。',
     '品質管理', NULL, NULL, NULL, NULL, NULL, '業務規程')
  ) AS v(document_id, day_offset, document_type, title, body, author_role,
         region_name, store_id, product_id, supplier_id, case_id, source_system)
  CROSS JOIN SWT_CW_HANDSON.CORE.V_PARAMS p
),
noise_seq AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS seq_no
  FROM TABLE(GENERATOR(ROWCOUNT => 120))
),
-- ノイズ文書を12店舗・12商品へ均等に散らすための連番付きマスタ
stores_idx AS (
  SELECT store_id, region_name,
         ROW_NUMBER() OVER (ORDER BY store_id) - 1 AS idx
  FROM SWT_CW_HANDSON.CORE.DIM_STORE
),
products_idx AS (
  SELECT product_id, supplier_id,
         ROW_NUMBER() OVER (ORDER BY product_id) - 1 AS idx
  FROM SWT_CW_HANDSON.CORE.DIM_PRODUCT
),
noise AS (
  SELECT
    'DOC-G' || LPAD(n.seq_no::VARCHAR, 4, '0')                      AS document_id,
    DATEADD(day, MOD(n.seq_no * 7, 175), p.data_start)::DATE        AS document_date,
    CASE MOD(n.seq_no - 1, 6)
      WHEN 0 THEN '店舗週報'   WHEN 1 THEN '顧客の声サマリー'
      WHEN 2 THEN '物流連絡'   WHEN 3 THEN '販促レビュー'
      WHEN 4 THEN '過去対応事例' ELSE '業務FAQ'
    END                                                              AS document_type,
    'クレストリヴェルタ業務文書 ' || LPAD(n.seq_no::VARCHAR, 4, '0')   AS title,
    CASE MOD(n.seq_no - 1, 6)
      WHEN 0 THEN '対象店舗では定番商品の販売と補充は通常範囲だった。週末は来店数が増えたが、重大な欠品や返品増加は確認されていない。次週も通常の発注計画を継続する。'
      WHEN 1 THEN 'お客様からは品ぞろえと接客に関する一般的な意見が寄せられた。特定商品に集中した苦情はなく、価格、在庫、品質のいずれにも継続的な異常は確認されていない。'
      WHEN 2 THEN '定期便は予定どおり到着した。道路状況による到着時刻の小幅な変動はあったが、店舗営業や在庫水準に影響する遅延は発生していない。'
      WHEN 3 THEN '販促期間中の販売数量は計画範囲内だった。値引率と粗利率のバランスを確認し、追加施策は実施せず通常運用へ戻す。'
      WHEN 4 THEN '過去の類似事例では、数値と現場報告を分けて確認し、原因候補ごとに追加データを検証した。単一のコメントだけで原因を断定しないことが再発防止につながった。'
      ELSE '業績異常を確認する際は、売上だけでなく需要、販売数量、返品、値引き、欠品、粗利を確認する。文書の見解は数値データと照合してから意思決定に利用する。'
    END || ' 文書番号は' || n.seq_no || '。'                          AS body,
    CASE MOD(n.seq_no - 1, 6)
      WHEN 0 THEN '店長'       WHEN 1 THEN 'VOC分析担当' WHEN 2 THEN '物流担当'
      WHEN 3 THEN '販促担当'   WHEN 4 THEN '業務改善担当' ELSE '業務統括'
    END                                                              AS author_role,
    st.region_name,
    st.store_id,
    pr.product_id,
    pr.supplier_id,
    NULL                                                             AS case_id,
    '社内限定'                                                        AS confidentiality,
    CASE MOD(n.seq_no - 1, 3)
      WHEN 0 THEN '店舗運営ポータル' WHEN 1 THEN 'お客様相談室' ELSE '社内ナレッジ'
    END                                                              AS source_system
  FROM noise_seq n
  CROSS JOIN SWT_CW_HANDSON.CORE.V_PARAMS p
  JOIN stores_idx   st ON st.idx = MOD(n.seq_no - 1, 12)
  JOIN products_idx pr ON pr.idx = MOD(n.seq_no * 5 - 1, 12)
)
SELECT document_id, document_date, document_type, title, body, author_role,
       region_name, store_id, product_id, supplier_id, case_id,
       confidentiality, source_system
FROM curated
UNION ALL
SELECT document_id, document_date, document_type, title, body, author_role,
       region_name, store_id, product_id, supplier_id, case_id,
       confidentiality, source_system
FROM noise;

ALTER TABLE SWT_CW_HANDSON.DOCUMENTS.DOCUMENT_CORPUS SET CHANGE_TRACKING = TRUE;


-- =============================================================================
-- 6. 元PDFを置く内部ステージ
--
--    ここから読むPDF（リポジトリの out/pdf/ にある）
--      S017_月次業績報告_P042.pdf  (MANAGER_REPORTのSOURCE_FILEと一致させる)
--      S008_月次業績報告_P042.pdf
--      S031_月次業績報告_P042.pdf
--      S017_月次業績報告_P057.pdf
--
--    CREATE OR REPLACE にしない理由
--      作り直すとアップロード済みのPDFが消える。再実行を前提にしているため
--      IF NOT EXISTS で既存ステージを残す。
--
--    ENCRYPTION = SNOWFLAKE_SSE
--      2026-08-20 GA 以降は AI_PARSE_DOCUMENT がクライアント側暗号化の
--      ステージにも対応したが、古い挙動やSnowsightでのプレビューとの互換を考え
--      サーバー側暗号化にしておく。
--
--    アップロード方法（どちらか）
--      Snowsight: Data > Databases > SWT_CW_HANDSON > DOCUMENTS > Stages >
--                 STG_SOURCE_PDF > + Files で4本を選ぶ
--      Snowflake CLI:
--        snow stage copy "out/pdf/*_月次業績報告_*.pdf" @SWT_CW_HANDSON.DOCUMENTS.STG_SOURCE_PDF
-- =============================================================================
CREATE STAGE IF NOT EXISTS SWT_CW_HANDSON.DOCUMENTS.STG_SOURCE_PDF
  DIRECTORY = (ENABLE = TRUE)
  ENCRYPTION = (TYPE = 'SNOWFLAKE_SSE')
  COMMENT = '月次業績報告の元PDF。out/pdf/ の4本をアップロードする';

ALTER STAGE SWT_CW_HANDSON.DOCUMENTS.STG_SOURCE_PDF REFRESH;

-- ★ PDFが4本揃っていなければここで止める。
--    アップロード後にこのファイルを最初から再実行すること。
EXECUTE IMMEDIATE $$
DECLARE
  pdf_missing EXCEPTION (-20001,
    '報告書PDFが4本揃っていない。out/pdf/ の *_月次業績報告_*.pdf を @SWT_CW_HANDSON.DOCUMENTS.STG_SOURCE_PDF にアップロードしてから 01_setup.sql を再実行する');
BEGIN
  LET n INTEGER := (
    SELECT COUNT(*)
    FROM DIRECTORY(@SWT_CW_HANDSON.DOCUMENTS.STG_SOURCE_PDF)
    WHERE RELATIVE_PATH IN ('S017_月次業績報告_P042.pdf',
                            'S008_月次業績報告_P042.pdf',
                            'S031_月次業績報告_P042.pdf',
                            'S017_月次業績報告_P057.pdf'));
  IF (n < 4) THEN
    RAISE pdf_missing;
  END IF;
  RETURN 'PASS 報告書PDF 4本を確認';
END;
$$;


-- =============================================================================
-- 7. 部下からの月次業績報告（4件）
--
--    設計の核心: 報告書は嘘を書いていない。しかし不都合を書いていない。
--
--    店舗/商品   報告書の主張              触れていない事実
--    S017/P042   「98%着地、影響は軽微」    充足率76% 返品率8.5% 値引12% 粗利29%
--    S008/P042   「127%、欠品なし」         なし（完全に整合）
--    S031/P042   「77%未達、原因は納品数量」なし（正直な未達報告）
--    S017/P057   「91%、在庫問題なし」      粗利率17%（粗利に一切言及なし）
--
--    S031は「未達を正直に報告している = 実は管理できている」という
--    逆説を体験させるために必要。未達＝悪ではないことを気づかせる。
--
--    文書日付は販促終了日を基準にした相対日数で生成する。
--    本文に絶対的な月表記を書かないこと。実施日とずれる。
--
--    本文（BODY）は AI_PARSE_DOCUMENT でPDFから文字起こしする。
--    属性列はPDFから安定して取れないためメタデータとしてここに残す。
--    取ろうとすればそれ自体が新たな不確定要素になる。
--      PDF由来  : BODY
--      SQL由来  : REPORT_ID / STORE_ID / PRODUCT_ID / CASE_ID / AUTHOR_NAME /
--                 REPORTED_ATTAINMENT_TEXT / TITLE / DAY_OFFSET
--
--    LAYOUTモードを使う理由: 実績サマリーの表をMarkdown表として復元できる。
--    OCRモードは表構造が崩れて列が繋がる。
--    ヘッダー・フッター・免責文は落とさない。実務のPDFは定型文だらけで、
--    それを含んだまま検索が効くことを見せるほうが誠実である。
-- =============================================================================
CREATE OR REPLACE TABLE SWT_CW_HANDSON.DOCUMENTS.MANAGER_REPORT AS
WITH meta AS (
  SELECT * FROM (VALUES
    -- -------------------------------------------------------------------------
    -- 主役。最も危険な報告書。
    -- 「計画比98パーセント」を成果として報告し、
    -- 入荷不足を「概ね回復」「影響は軽微」と過小評価している。
    -- 返品・値引き・粗利には一切触れていない。
    -- -------------------------------------------------------------------------
    ('RPT-S017-P042', 3, '月次業績報告',
     '横浜みなと店 クレストリフレッシュウォーター 月次業績報告',
     '店長', '田村 秀樹', '関東', 'S017', '横浜みなと店',
     'P042', 'クレストリフレッシュウォーター',
     '計画比98パーセントで着地', 'FOCAL_PROMO_SUPPLY',
     'S017_月次業績報告_P042.pdf'),

    -- -------------------------------------------------------------------------
    -- 健全な成功例。報告書と数値が完全に整合する。
    -- 「報告書が信頼できるとはどういう状態か」の基準として必要。
    -- -------------------------------------------------------------------------
    ('RPT-S008-P042', 2, '月次業績報告',
     '東京ベイ店 クレストリフレッシュウォーター 月次業績報告',
     '店長', '西野 亜矢', '関東', 'S008', '東京ベイ店',
     'P042', 'クレストリフレッシュウォーター',
     '計画比127パーセント', 'CMP_HEALTHY_PROMO',
     'S008_月次業績報告_P042.pdf'),

    -- -------------------------------------------------------------------------
    -- 正直な未達報告。数値と完全に整合し、原因も自分で特定できている。
    -- 「未達だが管理できている」状態。主役との対比が教育上の要点。
    -- -------------------------------------------------------------------------
    ('RPT-S031-P042', 4, '月次業績報告',
     '名古屋ささしま店 クレストリフレッシュウォーター 月次業績報告',
     '店長', '堀内 康平', '中部', 'S031', '名古屋ささしま店',
     'P042', 'クレストリフレッシュウォーター',
     '計画比77パーセントと未達', 'CMP_SUPPLY_ONLY',
     'S031_月次業績報告_P042.pdf'),

    -- -------------------------------------------------------------------------
    -- 「書かれていないことに気づく」ケース。
    -- 在庫・欠品・返品には触れているが、粗利には一言も言及がない。
    -- 実際の粗利率は17パーセントまで悪化している。
    -- -------------------------------------------------------------------------
    ('RPT-S017-P057', 3, '月次業績報告',
     '横浜みなと店 リヴェルタ冷凍パスタ 月次業績報告',
     '店長', '田村 秀樹', '関東', 'S017', '横浜みなと店',
     'P057', 'リヴェルタ冷凍パスタ',
     '計画比91パーセント', 'CMP_MARGIN_ONLY',
     'S017_月次業績報告_P057.pdf')
  ) AS v(report_id, day_offset, report_type, title, author_role, author_name,
         region_name, store_id, store_name, product_id, product_name,
         reported_attainment_text, case_id, source_file)
),
parsed AS (
  -- PDF1本ごとに1回だけ解析する。4本 x 1ページなので数十秒で終わる。
  SELECT
    m.source_file,
    TO_VARCHAR(
      AI_PARSE_DOCUMENT(
        TO_FILE('@SWT_CW_HANDSON.DOCUMENTS.STG_SOURCE_PDF', m.source_file),
        {'mode': 'LAYOUT'}
      ):content
    ) AS body
  FROM meta m
)
SELECT
  m.report_id,
  DATEADD(day, m.day_offset, p.promo_end)::DATE AS report_date,
  m.report_type,
  m.title,
  d.body,
  m.author_role,
  m.author_name,
  m.region_name,
  m.store_id,
  m.store_name,
  m.product_id,
  m.product_name,
  m.reported_attainment_text,
  m.case_id,
  m.source_file,
  '社内限定' AS confidentiality
FROM meta m
JOIN parsed d ON d.source_file = m.source_file
CROSS JOIN SWT_CW_HANDSON.CORE.V_PARAMS p;

ALTER TABLE SWT_CW_HANDSON.DOCUMENTS.MANAGER_REPORT SET CHANGE_TRACKING = TRUE;

-- -----------------------------------------------------------------------------
-- 旧方式（本文をSQLに直接埋め込む）の本文リテラル。
--
-- AI_PARSE_DOCUMENT の日本語品質が当日までに劣化した場合の退避手段として残す。
-- 復帰させるときは meta の列に body を戻し、parsed CTE と JOIN を削除する。
-- 下記は scripts/build_handson_assets.py がPDFに書き込む本文と同一である。
--
-- RPT-S017-P042:
--   '担当店舗の当月実績についてご報告します。クレストリフレッシュウォーターは地域SNS施策の効果により指名買いが増加し、純売上は計画比98パーセントで着地しました。施策の認知度は高く、若年層の新規来店にもつながっている実感があります。売り場でもお客様から商品名を挙げてお問い合わせいただく場面が増えました。なお一部の平日で入荷数量が想定を下回る場面がありましたが、翌日以降の納品で概ね回復しており、売上への影響は軽微と判断しています。次月も同様の施策を継続いただきたく、あわせてご検討をお願いします。'
--
-- RPT-S008-P042:
--   'クレストリフレッシュウォーターについてご報告します。施策の公開予定を事前に共有いただけたため、需要増を見込んで初回納品を通常比1.4倍に引き上げました。結果として純売上は計画比127パーセントとなり、期間中の欠品は発生していません。入荷時に外装変形が疑われる商品を分離して売り場に出さない運用としたため、返品も通常水準に収まっています。値引きは計画どおり10パーセントの範囲で運用し、粗利への影響も想定内です。事前連絡が早かったことが最大の要因と考えています。'
--
-- RPT-S031-P042:
--   'クレストリフレッシュウォーターについてご報告します。一部の平日で入荷数量が通常を下回り、短時間の欠品が発生しました。純売上は計画比77パーセントと未達であり、達成できなかった要因は納品数量にあると考えています。当店では販促による需要の上振れは確認できておらず、値引きは3パーセントに留めています。返品も通常水準で、商品品質に関するお客様のご指摘はありません。調達部門と発注数量の見直しを協議しており、次月には通常水準へ戻せる見込みです。'
--
-- RPT-S017-P057:
--   'リヴェルタ冷凍パスタについてご報告します。近隣競合の価格訴求が続いたため、これに対応する形で期間中の値引きを継続しました。販売数量は前月比で微増し、純売上は計画比91パーセントです。在庫と納品には問題がなく、欠品や返品も発生していません。お客様からは価格に対する好意的な反応をいただいており、値引きの継続は集客に寄与していると考えています。競合の動きが続く限り、当面は現在の価格運用を維持したいと考えております。'
-- -----------------------------------------------------------------------------


-- =============================================================================
-- 8. 顧客レビュー（約620件）
--
--    セクション5のDOC-F004「顧客の声サマリー」は分析担当が要約した二次情報。
--    ここでは顧客の生の声を持たせる。返品率8.5パーセントという数字の
--    「なぜ」がレビュー本文に書かれている状態にする。
--
--    ケースごとのレビュー内容の設計
--      FOCAL_PROMO_SUPPLY : 欠品 + 外装つぶれ + 賞味期限。★1〜3
--      CMP_HEALTHY_PROMO  : 在庫あり・状態良好。★4〜5
--      CMP_SUPPLY_ONLY    : 欠品のみ。品質への言及は一切なし。★2〜4
--      CMP_MARGIN_ONLY    : 価格への好意的反応。品質・在庫問題なし。★4〜5
--      それ以外           : 一般的な内容。★3〜5
--
--    CMP_SUPPLY_ONLYで品質に触れないことが重要。
--    「欠品はどちらの店でも起きているが、品質劣化は主役店舗だけ」
--    という差分自体が、押し込み販売という真因を指す診断材料になる。
-- =============================================================================
CREATE OR REPLACE TABLE SWT_CW_HANDSON.DOCUMENTS.CUSTOMER_REVIEW AS
WITH combo AS (
  SELECT
    st.store_id, st.store_name, st.region_name,
    pr.product_id, pr.product_name, pr.category_name
  FROM SWT_CW_HANDSON.CORE.DIM_STORE st
  CROSS JOIN SWT_CW_HANDSON.CORE.DIM_PRODUCT pr
),
-- 全144組み合わせに4件ずつ = 576件
base_seq AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS k
  FROM TABLE(GENERATOR(ROWCOUNT => 4))
),
base AS (
  SELECT
    c.*,
    b.k,
    'B' AS row_kind,
    DATEADD(
      day,
      MOD(BITAND(HASH(c.store_id, c.product_id, b.k, 'RVDATE_V2'),
                 9223372036854775807), 180),
      p.data_start
    )::DATE AS review_date
  FROM combo c
  CROSS JOIN base_seq b
  CROSS JOIN SWT_CW_HANDSON.CORE.V_PARAMS p
),
-- 4ケースの組み合わせにだけ販促期間内の追加レビューを積む
-- 主役は24件、対照は各8件。主役の声が埋もれないようにする
extra_seq AS (
  SELECT ROW_NUMBER() OVER (ORDER BY SEQ4()) AS k
  FROM TABLE(GENERATOR(ROWCOUNT => 24))
),
extra AS (
  SELECT
    c.*,
    e.k + 100 AS k,
    'E' AS row_kind,
    DATEADD(
      day,
      MOD(BITAND(HASH(c.store_id, c.product_id, e.k, 'RVEX_V2'),
                 9223372036854775807),
          DATEDIFF(day, p.promo_start, p.promo_end) + 1),
      p.promo_start
    )::DATE AS review_date
  FROM combo c
  CROSS JOIN extra_seq e
  CROSS JOIN SWT_CW_HANDSON.CORE.V_PARAMS p
  WHERE (c.store_id = 'S017' AND c.product_id = 'P042')
     OR (c.store_id = 'S008' AND c.product_id = 'P042' AND e.k <= 8)
     OR (c.store_id = 'S031' AND c.product_id = 'P042' AND e.k <= 8)
     OR (c.store_id = 'S017' AND c.product_id = 'P057' AND e.k <= 8)
),
unioned AS (
  SELECT * FROM base
  UNION ALL
  SELECT * FROM extra
),
-- ケース判定はFACT_STORE_PRODUCT_DAYと同一のロジックに揃える
tagged AS (
  SELECT
    u.*,
    IFF(u.review_date BETWEEN p.promo_start AND p.promo_end,
      CASE
        WHEN u.store_id = 'S017' AND u.product_id = 'P042' THEN 'FOCAL_PROMO_SUPPLY'
        WHEN u.store_id = 'S008' AND u.product_id = 'P042' THEN 'CMP_HEALTHY_PROMO'
        WHEN u.store_id = 'S031' AND u.product_id = 'P042' THEN 'CMP_SUPPLY_ONLY'
        WHEN u.store_id = 'S017' AND u.product_id = 'P057' THEN 'CMP_MARGIN_ONLY'
      END,
      NULL
    ) AS case_id,
    MOD(BITAND(HASH(u.store_id, u.product_id, u.k, 'RVBUCKET_V2'),
               9223372036854775807), 6) AS bucket
  FROM unioned u
  CROSS JOIN SWT_CW_HANDSON.CORE.V_PARAMS p
)
SELECT
  'RV-' || LPAD(ROW_NUMBER() OVER (ORDER BY review_date, store_id, product_id, k)::VARCHAR,
                5, '0')                                            AS review_id,
  review_date,
  store_id,
  store_name,
  region_name,
  product_id,
  product_name,
  category_name,
  -- 評価スコア
  CASE case_id
    WHEN 'FOCAL_PROMO_SUPPLY' THEN 1 + MOD(bucket, 3)   -- 1〜3
    WHEN 'CMP_SUPPLY_ONLY'    THEN 2 + MOD(bucket, 3)   -- 2〜4
    WHEN 'CMP_HEALTHY_PROMO'  THEN 4 + MOD(bucket, 2)   -- 4〜5
    WHEN 'CMP_MARGIN_ONLY'    THEN 4 + MOD(bucket, 2)   -- 4〜5
    ELSE 3 + MOD(bucket, 3)                             -- 3〜5
  END::NUMBER(2,0)                                                 AS rating,
  -- レビュー本文
  CASE case_id
    WHEN 'FOCAL_PROMO_SUPPLY' THEN
      CASE bucket
        WHEN 0 THEN '夕方に立ち寄ったら売り切れていました。SNSで見て買いに来たので残念です。いつ入荷するか店員さんに聞いても分からないと言われました。'
        WHEN 1 THEN '外箱がへこんだ状態で並んでいました。中身に問題はなさそうでしたが、贈り物には使いにくいので選ぶのをやめました。'
        WHEN 2 THEN '賞味期限が思っていたより近いものが棚に出ていました。まとめ買いしたかったので少し不安になりました。'
        WHEN 3 THEN '別の店舗で買ったものと箱の状態が違いました。こちらの店のものは角がつぶれていて、同じ商品とは思えませんでした。'
        WHEN 4 THEN '値引きされていたのはありがたいのですが、パッケージが傷んでいるものが多く手に取りにくかったです。結局1本だけ買いました。'
        ELSE '何度か来ていますが平日の午後はいつも品切れです。人気なのは分かりますが、買えないことが続くと足が向かなくなります。'
      END
    WHEN 'CMP_HEALTHY_PROMO' THEN
      CASE bucket
        WHEN 0 THEN 'SNSで話題になっていたので買いに来ました。しっかり在庫があってすぐ買えたので助かりました。'
        WHEN 1 THEN '在庫が十分あって、まとめ買いできました。箱もきれいな状態でした。'
        WHEN 2 THEN '評判どおりの飲みやすさでした。売り場も分かりやすく並んでいて探しやすかったです。'
        WHEN 3 THEN '週末に行きましたが在庫は問題なくありました。家族の分もまとめて買えて満足です。'
        WHEN 4 THEN '割引もされていて買いやすかったです。商品の状態もよく、また買いに来ます。'
        ELSE '欲しいときにいつでも買えるのがありがたいです。売り場が整っていて気持ちよく買い物できました。'
      END
    WHEN 'CMP_SUPPLY_ONLY' THEN
      CASE bucket
        WHEN 0 THEN '行った時間帯に在庫がありませんでした。次の入荷を待つことにします。'
        WHEN 1 THEN '平日の夕方は棚が空いていることが多いです。商品自体は気に入っています。'
        WHEN 2 THEN '買えた分には満足していますが、希望の本数がそろわなかったのが残念でした。'
        WHEN 3 THEN '在庫が少なめでした。品質には問題なく、味も好みです。'
        WHEN 4 THEN '売り切れていて買えませんでした。入荷日が分かると助かります。'
        ELSE '数量限定のように少ししか並んでいませんでした。商品は良いので在庫を増やしてほしいです。'
      END
    WHEN 'CMP_MARGIN_ONLY' THEN
      CASE bucket
        WHEN 0 THEN '他店より安かったので買いました。味も家族に好評でした。'
        WHEN 1 THEN 'この価格ならリピートします。在庫も十分ありました。'
        WHEN 2 THEN 'セール価格だったのでまとめ買いしました。冷凍庫に常備しています。'
        WHEN 3 THEN '安く買えて満足です。パッケージも問題ありませんでした。'
        WHEN 4 THEN '価格が下がっていたので試してみました。想像より本格的な味で驚きました。'
        ELSE '近所の店より安いので、いつもここで買っています。品切れもありません。'
      END
    ELSE
      CASE bucket
        WHEN 0 THEN '普段から使っている商品です。特に問題なく買えました。'
        WHEN 1 THEN '店内が清潔で買い物しやすいです。品ぞろえにも満足しています。'
        WHEN 2 THEN 'レジの待ち時間が短くて助かりました。商品も探しやすい配置でした。'
        WHEN 3 THEN 'いつもの商品を買いました。価格に見合う品質だと思います。'
        WHEN 4 THEN '店員さんの対応が丁寧でした。また利用します。'
        ELSE '在庫も価格も特に気になる点はありませんでした。'
      END
  END                                                              AS review_text,
  case_id,
  '来店後アンケート' AS source_system
FROM tagged;

ALTER TABLE SWT_CW_HANDSON.DOCUMENTS.CUSTOMER_REVIEW SET CHANGE_TRACKING = TRUE;


-- =============================================================================
-- 9. Cortex Search Service: 社内文書コーパス
--    TARGET_LAGは1日。ハンズオン中に文書は変化しないため十分。
--    INITIALIZE = ON_CREATE のため、作成直後はindexing_stateがBUILDINGになる。
--    02_verify.sql でACTIVEを確認してから参加者へ配布する。
-- =============================================================================
CREATE OR REPLACE CORTEX SEARCH SERVICE SWT_CW_HANDSON.DOCUMENTS.ENTERPRISE_DOCUMENT_SEARCH
  ON body
  PRIMARY KEY (document_id)
  ATTRIBUTES region_name, store_id, product_id, document_type, document_date,
             case_id, confidentiality
  WAREHOUSE = COMPUTE_WH
  TARGET_LAG = '1 day'
  EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
  INITIALIZE = ON_CREATE
  AUTO_SUSPEND = 1800
  COMMENT = 'クレストリヴェルタの店舗日報、顧客の声、物流連絡、業務ポリシー、過去事例を検索する'
AS
SELECT
  document_id, document_date, document_type, title, body, author_role,
  region_name, store_id, product_id, supplier_id, case_id,
  confidentiality, source_system
FROM SWT_CW_HANDSON.DOCUMENTS.DOCUMENT_CORPUS;


-- =============================================================================
-- 10. Cortex Search Service: 部下報告書
--
--    4件しかないため検索難易度はゼロに近い。
--    Searchを使う理由は「難しい検索をさせること」ではなく
--    Agentが報告書だけを参照範囲にできる独立したツールを持つこと。
--    これにより実習1で既存コーパス（真因が書かれたDOC-F005を含む）を
--    引いてこないようにできる。
-- =============================================================================
CREATE OR REPLACE CORTEX SEARCH SERVICE SWT_CW_HANDSON.DOCUMENTS.MANAGER_REPORT_SEARCH
  ON body
  PRIMARY KEY (report_id)
  ATTRIBUTES store_id, store_name, product_id, region_name, report_date,
             report_type, author_role, case_id, source_file
  WAREHOUSE = COMPUTE_WH
  TARGET_LAG = '1 day'
  EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
  INITIALIZE = ON_CREATE
  AUTO_SUSPEND = 1800
  COMMENT = '各店舗の店長から事業責任者へ提出された月次業績報告'
AS
SELECT
  report_id, report_date, report_type, title, body,
  author_role, author_name, region_name, store_id, store_name,
  product_id, product_name, reported_attainment_text,
  case_id, source_file, confidentiality
FROM SWT_CW_HANDSON.DOCUMENTS.MANAGER_REPORT;


-- =============================================================================
-- 11. Cortex Search Service: 顧客レビュー
--
--    ratingをfilterableにしておくことで「低評価だけを見る」ができる。
--    ただしレビュー件数の集計や平均★の推移には使えない。
--    数量的な分析はSemantic View側の責務であり、混同させない。
-- =============================================================================
CREATE OR REPLACE CORTEX SEARCH SERVICE SWT_CW_HANDSON.DOCUMENTS.CUSTOMER_REVIEW_SEARCH
  ON review_text
  PRIMARY KEY (review_id)
  ATTRIBUTES store_id, store_name, product_id, product_name,
             region_name, review_date, rating, category_name, case_id
  WAREHOUSE = COMPUTE_WH
  TARGET_LAG = '1 day'
  EMBEDDING_MODEL = 'snowflake-arctic-embed-l-v2.0'
  INITIALIZE = ON_CREATE
  AUTO_SUSPEND = 1800
  COMMENT = '来店後アンケートで収集した顧客の自由記述レビューと5段階評価'
AS
SELECT
  review_id, review_date, store_id, store_name, region_name,
  product_id, product_name, category_name, rating, review_text,
  case_id, source_system
FROM SWT_CW_HANDSON.DOCUMENTS.CUSTOMER_REVIEW;


-- =============================================================================
-- 12. Semantic View
--    率はすべてmetricとして定義する。行ごとの率を平均すると誤った値になるため。
-- =============================================================================
CREATE OR REPLACE SEMANTIC VIEW SWT_CW_HANDSON.SEMANTIC.RETAIL_PERFORMANCE
  TABLES (
    performance AS SWT_CW_HANDSON.CORE.FACT_STORE_PRODUCT_DAY
      PRIMARY KEY (sales_date, store_id, product_id)
      COMMENT = 'クレストリヴェルタの店舗商品日次実績。直近180日分を収録'
  )
  FACTS (
    performance.demand_units AS demand_units
      COMMENT = '顧客需要数量。販売できなかった需要も含む',
    performance.sold_units AS sold_units
      COMMENT = '販売数量',
    performance.returned_units AS returned_units
      COMMENT = '返品数量',
    performance.list_sales_yen AS list_sales_yen
      COMMENT = '値引き前売上金額、円',
    performance.discount_yen AS discount_yen
      COMMENT = '値引金額、円',
    performance.return_yen AS return_yen
      COMMENT = '返品控除金額、円',
    performance.net_sales_yen AS net_sales_yen
      COMMENT = '値引きと返品控除後の純売上、円',
    performance.cogs_yen AS cogs_yen
      COMMENT = '返品を除いた販売商品の売上原価、円',
    performance.target_net_sales_yen AS target_net_sales_yen
      COMMENT = '純売上目標、円。販促による上振れを含まない素の計画値',
    performance.stockout_minutes AS stockout_minutes
      COMMENT = '1日あたりの欠品時間、分'
  )
  DIMENSIONS (
    performance.sales_date AS sales_date
      COMMENT = '実績日',
    performance.sales_month AS DATE_TRUNC('month', sales_date)
      WITH SYNONYMS = ('月次', '月別')
      COMMENT = '実績月',
    performance.store_id AS store_id
      COMMENT = '店舗ID。例 S017',
    performance.store_name AS store_name
      COMMENT = '店舗名。例 横浜みなと店',
    performance.region_name AS region_name
      COMMENT = '地域名'
      SAMPLE_VALUES ('北海道・東北', '関東', '中部', '関西', '中国・四国', '九州')
      IS_ENUM,
    performance.store_format AS store_format
      COMMENT = '店舗形態'
      SAMPLE_VALUES ('都市型', '郊外型', '小型')
      IS_ENUM,
    performance.product_id AS product_id
      COMMENT = '商品ID。例 P042',
    performance.product_name AS product_name
      COMMENT = '商品名。例 クレストリフレッシュウォーター',
    performance.category_name AS category_name
      COMMENT = '商品カテゴリー'
      SAMPLE_VALUES ('飲料', '加工食品', '菓子', '日用品', '冷凍食品', 'ヘルスケア')
      IS_ENUM,
    performance.subcategory_name AS subcategory_name
      COMMENT = '商品サブカテゴリー',
    performance.supplier_id AS supplier_id
      COMMENT = '仕入先ID',
    performance.case_id AS case_id
      COMMENT = '検証用ケースID。通常データはNULL。回答の根拠には使わない'
  )
  METRICS (
    -- -------------------------------------------------------------------------
    -- シノニムは「業務語から一意に引けない指標」だけに付ける。
    -- 全項目に付けるとSemantic Viewのトークンが膨らみ、
    -- Analystに渡るコンテキストを圧迫して逆に精度が落ちる。
    --
    -- 付ける基準は次の3つ。
    --   1. 1つの業務語が複数の指標に割れる（欠品 → 時間 / 発生率 / 機会損失率）
    --   2. 額と率が対になっている（粗利額 / 粗利率、値引額 / 値引率）
    --   3. 裏返しの関係にある（需要充足率 / 機会損失率）
    -- total_demand_units のような複合語で一意に決まる指標には付けない。
    -- -------------------------------------------------------------------------
    performance.total_net_sales_yen AS SUM(net_sales_yen)
      WITH SYNONYMS = ('売上', '純売上', '売上高')
      COMMENT = '純売上合計、円',
    performance.total_target_net_sales_yen AS SUM(target_net_sales_yen)
      COMMENT = '純売上目標合計、円',
    performance.sales_plan_attainment_rate
      AS DIV0NULL(SUM(net_sales_yen), SUM(target_net_sales_yen))
      WITH SYNONYMS = ('達成率', '計画比', '計画達成率', '進捗率')
      COMMENT = '純売上の計画達成率。1が100パーセント',
    performance.total_demand_units AS SUM(demand_units)
      COMMENT = '需要数量合計',
    performance.total_sold_units AS SUM(sold_units)
      COMMENT = '販売数量合計',
    performance.total_returned_units AS SUM(returned_units)
      COMMENT = '返品数量合計',
    performance.demand_fill_rate AS DIV0NULL(SUM(sold_units), SUM(demand_units))
      WITH SYNONYMS = ('充足率', '需要充足率')
      COMMENT = '需要充足率。需要のうち販売できた割合',
    performance.lost_demand_rate
      AS DIV0NULL(SUM(demand_units) - SUM(sold_units), SUM(demand_units))
      WITH SYNONYMS = ('機会損失率', '販売機会損失', '取りこぼし')
      COMMENT = '機会損失率。需要のうち販売できなかった割合',
    performance.return_rate AS DIV0NULL(SUM(returned_units), SUM(sold_units))
      WITH SYNONYMS = ('返品率')
      COMMENT = '返品率。販売数量に対する返品数量',
    performance.discount_rate AS DIV0NULL(SUM(discount_yen), SUM(list_sales_yen))
      WITH SYNONYMS = ('値引率', '値引き率', '割引率')
      COMMENT = '加重値引率',
    performance.gross_margin_yen AS SUM(net_sales_yen - cogs_yen)
      WITH SYNONYMS = ('粗利額', '粗利金額', '売上総利益')
      COMMENT = '粗利額、円',
    performance.gross_margin_rate
      AS DIV0NULL(SUM(net_sales_yen - cogs_yen), SUM(net_sales_yen))
      WITH SYNONYMS = ('粗利率', '粗利益率', '売上総利益率')
      COMMENT = '加重粗利率',
    performance.total_stockout_hours AS SUM(stockout_minutes) / 60
      WITH SYNONYMS = ('欠品時間')
      COMMENT = '欠品時間合計、時間',
    performance.stockout_row_rate
      AS DIV0NULL(COUNT_IF(stockout_minutes > 0), COUNT(*))
      WITH SYNONYMS = ('欠品発生率', '欠品率')
      COMMENT = '選択した店舗商品日のうち欠品があった行の割合'
  )
  COMMENT = 'クレストリヴェルタの売上、需要、在庫、返品、値引き、粗利を分析するSemantic View'
  AI_SQL_GENERATION 'データは前日までの直近180日分を収録している。ユーザーが直近90日と言った場合はCURRENT_DATEから90日前までを対象にする。直近1か月は30日前までを対象にする。率は定義済みmetricを使い、行ごとの率を単純平均しない。店舗商品日より細かい粒度は存在しない。CASE_IDは検証補助であり、ユーザーが明示しない限り結論の根拠として表示しない。金額は円、率は回答時にパーセント表示する。'
  AI_QUESTION_CATEGORIZATION 'このSemantic Viewは架空小売企業クレストリヴェルタの業績分析専用。人事、個人情報、実在企業の情報には回答しない。原因を問われた場合、数値から確認できる事実と原因仮説を区別する。'

  -- ---------------------------------------------------------------------------
  -- 検証済みクエリ
  --
  -- 効果は2つある。
  --   1. 実習の主要質問で安定して正しいSQLが返る
  --   2. ONBOARDING_QUESTION TRUE によりUIに質問候補として表示される。
  --      BYOPCで40名が同時に始めるため、タイプ量とタイプミスによる脱落が減る。
  --
  -- 壊れた検証済みクエリはAnalystの精度を逆に落とす。
  -- 4本すべて実データで実行し、期待どおりの結果が出ることを確認済み
  -- （2026-09-04、Tokyo リージョンのBCEアカウント）。
  -- 変更したら必ず SELECT を単体で実行して通ることを確かめること。
  --
  -- SQL文字列の中で店舗IDや商品IDを指定するため、
  -- リテラルのシングルクォートは '' に二重化する必要がある。
  -- ---------------------------------------------------------------------------
  AI_VERIFIED_QUERIES (
    -- 実習1-2の山場。達成率だけを見ていると見落とす3指標を横並びにする。
    -- 横浜みなと店だけ達成率98%台なのに返品率と需要充足率が外れることが分かる。
    focal_product_kpi_by_store AS (
      QUESTION 'クレストリフレッシュウォーターの店舗別に、計画達成率と返品率と粗利率と需要充足率を比較してください'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             SWT_CW_HANDSON.SEMANTIC.RETAIL_PERFORMANCE
             DIMENSIONS performance.store_name, performance.product_name
             METRICS performance.sales_plan_attainment_rate,
                     performance.return_rate,
                     performance.gross_margin_rate,
                     performance.demand_fill_rate
             WHERE performance.sales_date >= CURRENT_DATE - 90
               AND performance.product_id = ''P042''
           ) ORDER BY STORE_NAME'
    ),
    -- 達成率だけで店舗を並べると「どこも問題なし」に見える。
    -- 上の質問と対比させることで、単一指標の危うさを体験できる。
    attainment_by_store AS (
      QUESTION '直近90日の店舗別の計画達成率と純売上を教えてください'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             SWT_CW_HANDSON.SEMANTIC.RETAIL_PERFORMANCE
             DIMENSIONS performance.store_name
             METRICS performance.sales_plan_attainment_rate,
                     performance.total_net_sales_yen
             WHERE performance.sales_date >= CURRENT_DATE - 90
           ) ORDER BY SALES_PLAN_ATTAINMENT_RATE'
    ),
    -- 事業計画資料の全社トレンド用。
    monthly_net_sales_trend AS (
      QUESTION '月別の純売上と粗利率の推移を教えてください'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             SWT_CW_HANDSON.SEMANTIC.RETAIL_PERFORMANCE
             DIMENSIONS performance.sales_month
             METRICS performance.total_net_sales_yen,
                     performance.gross_margin_rate
           ) ORDER BY SALES_MONTH'
    ),
    -- 実習1の対照ケース（S017 x P057）を引き出す。
    -- 粗利率と値引率を並べると、値引き継続が粗利を削っていることが見える。
    focal_store_margin_by_product AS (
      QUESTION '横浜みなと店の商品別の粗利率と値引率を教えてください'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             SWT_CW_HANDSON.SEMANTIC.RETAIL_PERFORMANCE
             DIMENSIONS performance.product_name
             METRICS performance.gross_margin_rate,
                     performance.discount_rate,
                     performance.total_net_sales_yen
             WHERE performance.store_id = ''S017''
               AND performance.sales_date >= CURRENT_DATE - 90
           ) ORDER BY GROSS_MARGIN_RATE'
    )
  );


-- =============================================================================
-- 12.5 Web検索の有効化（Agent3が使う）
--
--    ENABLE_CORTEX_WEBSEARCH は ACCOUNT レベルのパラメータで既定は false。
--    Snowsightの「AIとML » エージェント » 設定 » Web search」トグルと同じ設定。
--    ドキュメントにはUI手順しか書かれていないが、パラメータとして存在するため
--    SQLで設定できる。参加者40名にトグルを押させる手間を省くためここで行う。
--
--    引き受けたリスク
--      検索クエリと結果は Brave Search API を経由し Snowflake の外に出る。
--      SnowflakeはBraveとゼロデータ保持を契約しているが、
--      顧客環境で有効化する場合は必ず事前に合意を取ること。
--      本ハンズオンは使い捨てTrialアカウントかつ架空データのみのため許容する。
--
--    このパラメータが false のままでも Agent の CREATE は成功する。
--    実行時に初めて失敗するため 02_verify.sql で値を検査している。
-- =============================================================================
ALTER ACCOUNT SET ENABLE_CORTEX_WEBSEARCH = TRUE;


-- =============================================================================
-- 12.7 ガバナンス付録（ダイナミックデータマスキング / 行アクセスポリシー）
--
--    付録F専用のデータセット。実習1〜5で使うデータには一切影響しない。
--    CORE / DOCUMENTS / SEMANTIC の各スキーマには手を入れず、
--    GOVERNED スキーマに閉じ込めている。
--
--    ■ なぜ ACCOUNTADMIN 自身を制限しているのか
--
--    CoWork の Agent は参加者の現在のロールで動く。参加者は ACCOUNTADMIN。
--    ロールを切り替えさせずにポリシーの効果を見せるには、
--    参加者が使うロールそのものを対象にするしかない。
--    本番の設計では権限の強いロールが全件を見るのが普通であり、
--    これはハンズオンで効果を可視化するための意図的な逆転である。
--
--    副作用: 参加者が GOVERNED.CUSTOMER_CONTACT を直接 SELECT しても
--    関東エリアしか見えず、PII列はマスクされる。これが期待動作である。
--    他スキーマのデータには影響しない。
--
--    講師が生データを確認したい場合の逃げ道として SWT_DATA_STEWARD ロールを
--    用意し、このロールだけをマスク除外にしている。参加者の手順には含めない。
--
--    ■ なぜ Cortex Search Service を作らないのか
--
--    Cortex Search Service は作成時にインデックスを実体化する。検索はサービス
--    所有者の権限で構築されたインデックスを引くため、呼び出し元のマスキング
--    ポリシーが適用されない。PIIをSearchに載せると素の値が返る恐れがある。
--    ガバナンス付録は Cortex Analyst（セマンティックビュー）専用とする。
--    Analyst は生成したSQLを呼び出し元ロールで実行するため、
--    マスキングと行アクセスが確実に効く。
--    02_verify.sql の [21] で「Searchサービスが存在しないこと」を検査している。
--
--    ■ 適用順序
--
--    CREATE OR REPLACE TABLE はポリシーの付与を落とす。
--    データ投入 → ポリシー作成 → 付与 の順で書くこと。順序を変えると
--    投入時に自分自身の行アクセスポリシーで弾かれる。
-- =============================================================================
CREATE SCHEMA IF NOT EXISTS SWT_CW_HANDSON.GOVERNED;

-- 行アクセスポリシーのマッピングテーブル。
-- ロール名をポリシー本体にハードコードせず、テーブル駆動にしている。
CREATE OR REPLACE TABLE SWT_CW_HANDSON.GOVERNED.ROLE_REGION_MAP (
  role_name    STRING COMMENT 'ロール名',
  region_name  STRING COMMENT '閲覧を許可するエリア名。* は全件'
) COMMENT = '行アクセスポリシーの参照表';

INSERT INTO SWT_CW_HANDSON.GOVERNED.ROLE_REGION_MAP (role_name, region_name)
VALUES
  -- 講師が使うロール。参加者と同じ見え方にするため関東だけに絞る。
  -- ここを '*' にすると「講師の画面では全件見える」ことになり、
  -- 参加者への説明が食い違う。
  ('ACCOUNTADMIN',     '関東'),
  -- 参加者が使うロール。付録Fの主役。
  -- この行が抜けると参加者には1行も返らず、付録Fが成立しない。
  ('SWT_PARTICIPANT',  '関東'),
  -- 講師用。全エリアを見られる。マスキング除外も兼ねる。
  ('SWT_DATA_STEWARD', '*');

-- 顧客連絡先（架空PII 300件）。
-- メールは全件 @example.com、電話は 090 固定。実在の連絡先に見えないようにする。
-- 生成は既存データと同じ HASH ベースで決定論的。乱数は使わない。
CREATE OR REPLACE TABLE SWT_CW_HANDSON.GOVERNED.CUSTOMER_CONTACT AS
WITH seq AS (
  SELECT SEQ4() AS k FROM TABLE(GENERATOR(ROWCOUNT => 300))
),
sur AS (
  SELECT s, ROW_NUMBER() OVER (ORDER BY s) - 1 AS i FROM VALUES
    ('佐藤'),('鈴木'),('高橋'),('田中'),('伊藤'),
    ('渡辺'),('山本'),('中村'),('小林'),('加藤') AS v(s)
),
giv AS (
  SELECT g, ROW_NUMBER() OVER (ORDER BY g) - 1 AS i FROM VALUES
    ('太郎'),('花子'),('健一'),('美咲'),('翔太'),
    ('結衣'),('大輔'),('さくら'),('拓海'),('陽菜') AS v(g)
),
store AS (
  SELECT store_id, store_name, region_name,
         ROW_NUMBER() OVER (ORDER BY store_id) - 1 AS i,
         COUNT(*) OVER () AS n
  FROM SWT_CW_HANDSON.CORE.DIM_STORE
)
SELECT
  'C' || LPAD(s.k + 1, 5, '0')                                   AS customer_id,
  su.s || ' ' || gi.g                                            AS customer_name,
  'user' || LPAD(s.k + 1, 5, '0') || '@example.com'               AS email,
  '090-'
    || LPAD(MOD(BITAND(HASH(s.k, 'TEL1_V1'), 9223372036854775807), 10000), 4, '0')
    || '-'
    || LPAD(MOD(BITAND(HASH(s.k, 'TEL2_V1'), 9223372036854775807), 10000), 4, '0')
                                                                 AS phone,
  -- 20歳から60歳の範囲に散らす
  DATEADD(day,
    -MOD(BITAND(HASH(s.k, 'DOB_V1'), 9223372036854775807), 14601),
    DATEADD(year, -20, CURRENT_DATE()))::DATE                     AS birth_date,
  CASE MOD(BITAND(HASH(s.k, 'RANK_V1'), 9223372036854775807), 10)
    WHEN 0 THEN 'プラチナ'
    WHEN 1 THEN 'ゴールド'
    WHEN 2 THEN 'ゴールド'
    WHEN 3 THEN 'シルバー'
    WHEN 4 THEN 'シルバー'
    WHEN 5 THEN 'シルバー'
    ELSE 'レギュラー'
  END                                                            AS member_rank,
  st.region_name                                                 AS region_name,
  st.store_id                                                    AS store_id,
  st.store_name                                                  AS store_name,
  DATEADD(day,
    -MOD(BITAND(HASH(s.k, 'SIGNUP_V1'), 9223372036854775807), 1460),
    CURRENT_DATE())::DATE                                        AS signup_date,
  -- 会員ランクが上位ほど生涯購買額が大きくなるようにする
  (3000
    + MOD(BITAND(HASH(s.k, 'LTV_V1'), 9223372036854775807), 40000)
    + CASE MOD(BITAND(HASH(s.k, 'RANK_V1'), 9223372036854775807), 10)
        WHEN 0 THEN 260000
        WHEN 1 THEN 120000
        WHEN 2 THEN 120000
        ELSE 0
      END)::NUMBER(12,0)                                         AS lifetime_value_yen,
  -- ダイレクトメールの受け取り同意
  IFF(MOD(BITAND(HASH(s.k, 'CONSENT_V1'), 9223372036854775807), 4) = 0,
      FALSE, TRUE)                                               AS mail_consent
FROM seq s
JOIN sur su ON su.i = MOD(BITAND(HASH(s.k, 'SUR_V1'), 9223372036854775807), 10)
JOIN giv gi ON gi.i = MOD(BITAND(HASH(s.k, 'GIV_V1'), 9223372036854775807), 10)
JOIN store st
  ON st.i = MOD(BITAND(HASH(s.k, 'STORE_V1'), 9223372036854775807), st.n);


-- =============================================================================
-- 12.7.1 マスキングポリシー（4本）
--
--    戻り値の型は列の型と一致させる必要がある。
--    birth_date は DATE のままにしなければならないため、年だけ残す形にした。
--    VARCHAR で「40代」のように返すことはできない。
-- =============================================================================
CREATE OR REPLACE MASKING POLICY SWT_CW_HANDSON.GOVERNED.MASK_NAME
  AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() = 'SWT_DATA_STEWARD' THEN val
    ELSE SPLIT_PART(val, ' ', 1) || ' ＊＊'
  END
  COMMENT = 'データスチュワード以外には姓のみ表示する';

CREATE OR REPLACE MASKING POLICY SWT_CW_HANDSON.GOVERNED.MASK_EMAIL
  AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() = 'SWT_DATA_STEWARD' THEN val
    ELSE REGEXP_REPLACE(val, '^(.).*@', '\\1***@')
  END
  COMMENT = 'データスチュワード以外にはローカル部を伏せる';

CREATE OR REPLACE MASKING POLICY SWT_CW_HANDSON.GOVERNED.MASK_PHONE
  AS (val STRING) RETURNS STRING ->
  CASE
    WHEN CURRENT_ROLE() = 'SWT_DATA_STEWARD' THEN val
    ELSE LEFT(val, 4) || '****-' || RIGHT(val, 4)
  END
  COMMENT = 'データスチュワード以外には中間4桁を伏せる';

CREATE OR REPLACE MASKING POLICY SWT_CW_HANDSON.GOVERNED.MASK_BIRTH_DATE
  AS (val DATE) RETURNS DATE ->
  CASE
    WHEN CURRENT_ROLE() = 'SWT_DATA_STEWARD' THEN val
    ELSE DATE_FROM_PARTS(YEAR(val), 1, 1)
  END
  COMMENT = 'データスチュワード以外には生年のみ残す';


-- =============================================================================
-- 12.7.2 行アクセスポリシー（1本）
-- =============================================================================
CREATE OR REPLACE ROW ACCESS POLICY SWT_CW_HANDSON.GOVERNED.RAP_REGION
  AS (region_name STRING) RETURNS BOOLEAN ->
  EXISTS (
    SELECT 1
    FROM SWT_CW_HANDSON.GOVERNED.ROLE_REGION_MAP m
    WHERE m.role_name = CURRENT_ROLE()
      AND (m.region_name = '*' OR m.region_name = region_name)
  )
  COMMENT = 'ROLE_REGION_MAP に許可されたエリアの行だけを返す';


-- =============================================================================
-- 12.7.3 ポリシーの付与
--
--    ここより前でデータを投入し終えていること。
-- =============================================================================
ALTER TABLE SWT_CW_HANDSON.GOVERNED.CUSTOMER_CONTACT
  MODIFY COLUMN customer_name SET MASKING POLICY SWT_CW_HANDSON.GOVERNED.MASK_NAME;
ALTER TABLE SWT_CW_HANDSON.GOVERNED.CUSTOMER_CONTACT
  MODIFY COLUMN email SET MASKING POLICY SWT_CW_HANDSON.GOVERNED.MASK_EMAIL;
ALTER TABLE SWT_CW_HANDSON.GOVERNED.CUSTOMER_CONTACT
  MODIFY COLUMN phone SET MASKING POLICY SWT_CW_HANDSON.GOVERNED.MASK_PHONE;
ALTER TABLE SWT_CW_HANDSON.GOVERNED.CUSTOMER_CONTACT
  MODIFY COLUMN birth_date SET MASKING POLICY SWT_CW_HANDSON.GOVERNED.MASK_BIRTH_DATE;

ALTER TABLE SWT_CW_HANDSON.GOVERNED.CUSTOMER_CONTACT
  ADD ROW ACCESS POLICY SWT_CW_HANDSON.GOVERNED.RAP_REGION ON (region_name);


-- =============================================================================
-- 12.7.4 講師用のマスク除外ロール
--
--    参加者の手順には含めない。生データを確認したい場合にワークシートで
--    USE ROLE SWT_DATA_STEWARD; に切り替えて使う。
-- =============================================================================
CREATE ROLE IF NOT EXISTS SWT_DATA_STEWARD
  COMMENT = 'ハンズオン付録F用。マスキング除外ロール';
GRANT USAGE ON DATABASE SWT_CW_HANDSON TO ROLE SWT_DATA_STEWARD;
GRANT USAGE ON SCHEMA SWT_CW_HANDSON.GOVERNED TO ROLE SWT_DATA_STEWARD;
GRANT SELECT ON ALL TABLES IN SCHEMA SWT_CW_HANDSON.GOVERNED TO ROLE SWT_DATA_STEWARD;
GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE SWT_DATA_STEWARD;

EXECUTE IMMEDIATE $$
BEGIN
  -- IDENTIFIER(CURRENT_USER()) は使えない。IDENTIFIER は定数を要求するため
  -- 「invalid identifier」で失敗する。動的SQLで組み立てること。
  EXECUTE IMMEDIATE
    'GRANT ROLE SWT_DATA_STEWARD TO USER "' || CURRENT_USER() || '"';
EXCEPTION
  WHEN OTHER THEN
    -- 既に付与済みの場合や権限不足の場合は無視する。
    -- このロールは講師用の逃げ道であり、参加者の手順には必要ない。
    NULL;
END;
$$;


-- =============================================================================
-- 12.7.5 ガバナンス用 Semantic View
--
--    既存の SEMANTIC.RETAIL_PERFORMANCE とは完全に別のオブジェクト。
--    実習1〜5には影響しない。
--
--    マスクされた列を DIMENSIONS に含めている理由。
--    参加者に「AIが取ってきた値がマスクされている」ことを見せるのが目的なので、
--    氏名・メール・電話・生年月日を意図的に次元として公開している。
--    ただし customer_name でのGROUP BYはマスク後の値で集約されるため、
--    集計軸としては意味が薄い。AI_SQL_GENERATION でその旨を伝えている。
-- =============================================================================
CREATE OR REPLACE SEMANTIC VIEW SWT_CW_HANDSON.GOVERNED.CUSTOMER_GOVERNANCE
  TABLES (
    contact AS SWT_CW_HANDSON.GOVERNED.CUSTOMER_CONTACT
      PRIMARY KEY (customer_id)
      COMMENT = '顧客連絡先。架空の個人情報。マスキングと行アクセスポリシーが適用されている'
  )
  FACTS (
    contact.lifetime_value_yen AS lifetime_value_yen
      COMMENT = '入会以来の累計購買金額、円'
  )
  DIMENSIONS (
    contact.customer_id AS customer_id
      COMMENT = '顧客ID。例 C00017',
    contact.customer_name AS customer_name
      COMMENT = '顧客氏名。マスキングポリシーにより姓のみ表示される',
    contact.email AS email
      COMMENT = 'メールアドレス。マスキングポリシーによりローカル部が伏せられる',
    contact.phone AS phone
      COMMENT = '電話番号。マスキングポリシーにより中間4桁が伏せられる',
    contact.birth_date AS birth_date
      COMMENT = '生年月日。マスキングポリシーにより生年のみ残る',
    contact.member_rank AS member_rank
      WITH SYNONYMS = ('会員ランク', '会員区分')
      COMMENT = '会員ランク'
      SAMPLE_VALUES ('プラチナ', 'ゴールド', 'シルバー', 'レギュラー')
      IS_ENUM,
    contact.region_name AS region_name
      COMMENT = 'エリア名。行アクセスポリシーの判定に使われる列',
    contact.store_id AS store_id
      COMMENT = '主に利用する店舗ID',
    contact.store_name AS store_name
      COMMENT = '主に利用する店舗名',
    contact.signup_date AS signup_date
      COMMENT = '入会日',
    contact.mail_consent AS mail_consent
      COMMENT = 'ダイレクトメール受け取り同意フラグ'
  )
  METRICS (
    contact.customer_count AS COUNT(customer_id)
      WITH SYNONYMS = ('顧客数', '会員数')
      COMMENT = '顧客数',
    contact.total_lifetime_value_yen AS SUM(lifetime_value_yen)
      WITH SYNONYMS = ('累計購買額', '生涯購買額')
      COMMENT = '累計購買金額の合計、円',
    contact.avg_lifetime_value_yen AS AVG(lifetime_value_yen)
      WITH SYNONYMS = ('平均購買額', '平均生涯購買額')
      COMMENT = '1人あたり平均累計購買金額、円'
  )
  COMMENT = '付録F専用。マスキングと行アクセスポリシーの効果を確認するための顧客連絡先Semantic View'
  AI_SQL_GENERATION 'このSemantic Viewの顧客氏名、メールアドレス、電話番号、生年月日にはマスキングポリシーが適用されている。取得した値はマスクされた状態で返る。マスクを外す方法はなく、元の値を推測してもいけない。行アクセスポリシーも適用されており、実行ロールに許可されたエリアの行しか返らない。全体像を問われた場合も、見えている範囲での集計であることを前提にする。customer_nameでGROUP BYするとマスク後の値で集約されるため、集計軸には member_rank や region_name を使う。金額は円で表示する。'
  AI_QUESTION_CATEGORIZATION 'このSemantic Viewは架空小売企業クレストリヴェルタの顧客連絡先データ専用。ハンズオンで個人情報保護の仕組みを確認するために用意されている。売上、返品、粗利、欠品などの業績数値はこのSemantic Viewでは扱わない。実在の個人や企業の情報には回答しない。'
  AI_VERIFIED_QUERIES (
    contact_sample AS (
      QUESTION '顧客連絡先データを10件見せてください'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             SWT_CW_HANDSON.GOVERNED.CUSTOMER_GOVERNANCE
             DIMENSIONS contact.customer_id, contact.customer_name,
                        contact.email, contact.phone,
                        contact.birth_date, contact.region_name
           ) ORDER BY CUSTOMER_ID LIMIT 10'
    ),
    rank_summary AS (
      QUESTION '会員ランクごとの顧客数と平均生涯購買額を教えてください'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             SWT_CW_HANDSON.GOVERNED.CUSTOMER_GOVERNANCE
             DIMENSIONS contact.member_rank
             METRICS contact.customer_count, contact.avg_lifetime_value_yen
           ) ORDER BY CUSTOMER_COUNT DESC'
    ),
    region_visibility AS (
      QUESTION '顧客連絡先データはどのエリアが見えていますか'
      ONBOARDING_QUESTION TRUE
      SQL 'SELECT * FROM SEMANTIC_VIEW(
             SWT_CW_HANDSON.GOVERNED.CUSTOMER_GOVERNANCE
             DIMENSIONS contact.region_name
             METRICS contact.customer_count
           ) ORDER BY REGION_NAME'
    )
  );


-- =============================================================================
-- 12.8 参加者ロール
--
--    ハンズオン参加者は ACCOUNTADMIN を使わない。
--    このロール1本で実習1〜5と付録すべてが実行できるようにする。
--
--    ■ CoWork で Agent を使うために必要な権限（ドキュメント準拠）
--      USAGE  : データベース、スキーマ、Agent、Cortex Search Service、
--               Semantic View、ウェアハウス、SNOWFLAKE INTELLIGENCE オブジェクト
--      SELECT : Semantic View が参照するテーブル
--
--    Agent と SNOWFLAKE INTELLIGENCE への GRANT はここには書けない。
--    Agent はセクション13で作るため、セクション14 で付与する。
--
--    ■ 意図的に付与しないもの
--      CREATE 系すべて   : 参加者はオブジェクトを作らない
--      SWT_DATA_STEWARD  : マスキング除外は講師専用
--      ACCOUNTADMIN      : 言うまでもなく渡さない
--
--    ■ SNOWFLAKE.CORTEX_USER について
--      既定で PUBLIC に付与されているため明示的な GRANT は不要。
--      もしアカウント側で PUBLIC から revoke している場合は
--      GRANT DATABASE ROLE SNOWFLAKE.CORTEX_AGENT_USER が必要になる。
-- =============================================================================
CREATE ROLE IF NOT EXISTS SWT_PARTICIPANT
  COMMENT = 'ハンズオン参加者用。ACCOUNTADMINを渡さずに全実習を実行できる最小権限';

GRANT USAGE ON WAREHOUSE COMPUTE_WH TO ROLE SWT_PARTICIPANT;

GRANT USAGE ON DATABASE SWT_CW_HANDSON TO ROLE SWT_PARTICIPANT;
GRANT USAGE ON ALL SCHEMAS IN DATABASE SWT_CW_HANDSON TO ROLE SWT_PARTICIPANT;

-- Semantic View は裏のテーブルへの SELECT がないと動かない。
-- GOVERNED.CUSTOMER_CONTACT もここに含まれるが、
-- マスキングポリシーと行アクセスポリシーが効くので素の値は見えない。
GRANT SELECT ON ALL TABLES IN DATABASE SWT_CW_HANDSON TO ROLE SWT_PARTICIPANT;
GRANT SELECT ON ALL VIEWS  IN DATABASE SWT_CW_HANDSON TO ROLE SWT_PARTICIPANT;

-- Semantic View の権限は SELECT。USAGE ではない。
-- ドキュメント（User access and settings for agents）は
-- 「USAGE - Semantic view/model」と書いているが、実際に USAGE で GRANT すると
-- Invalid object type 'SEMANTIC_VIEW' for privilege 'USAGE' で失敗する。
-- 実測（2026-09-08 / AWS ap-northeast-1）に基づき SELECT を使う。
GRANT SELECT ON ALL SEMANTIC VIEWS IN DATABASE SWT_CW_HANDSON TO ROLE SWT_PARTICIPANT;
GRANT USAGE ON ALL CORTEX SEARCH SERVICES IN DATABASE SWT_CW_HANDSON
  TO ROLE SWT_PARTICIPANT;

-- 報告書PDFの元ステージ。実習では Search 経由で足りるが、
-- Agent が原本を参照しようとした場合に権限エラーで止まらないようにする。
GRANT READ ON STAGE SWT_CW_HANDSON.DOCUMENTS.STG_SOURCE_PDF TO ROLE SWT_PARTICIPANT;


-- =============================================================================
-- 13. Cortex Agent
--
--    ツール構成
--      - retail_performance_analytics : 数量的な分析（Semantic View）
--      - manager_report_search        : 実習1の主役ツール
--      - customer_review_search       : 実習2の主役ツール
--      - enterprise_document_search   : 社内文書コーパス
--      - data_to_chart                : グラフ化
--      - code_execution               : PPTX / PDF生成に必須
--      - web_search                   : Agent3のみ。外部の市場文脈を確認する
--      引用フォーマットは response instructions で強制する。
--
--    ツールが6本ある。3つのCortex Searchの使い分けを
--    Agentが誤る可能性があるため、descriptionで役割を明確に切り分ける。
--    リハーサルで最も重点的に確認すべき箇所。
--
--    permission_policy は既定の always_ask を明示的に指定する。
--    PPTX生成前に承認ボタンが出る。ガバナンスの仕組みを見せる価値があり
--    クリック1回の負担は許容する。運営Runbookに画面案内を記載すること。
-- =============================================================================
-- -----------------------------------------------------------------------------
-- クレストリヴェルタ 事業判断アシスタント ① 報告と数字
--    実習1・2で使う。報告書と数値のギャップから真因までを辿る4問。
-- -----------------------------------------------------------------------------
CREATE OR REPLACE AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_1
  COMMENT = 'SWT Tokyo ハンズオン 実習1と2用。報告書と数値の突き合わせ'
  PROFILE = '{"display_name":"クレストリヴェルタ 事業判断アシスタント ① 報告と数字","color":"blue"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  orchestration:
    budget:
      seconds: 300
      tokens: 64000

  instructions:
    orchestration: |
      あなたは架空の全国小売企業クレストリヴェルタの事業責任者を支援するエージェントです。
      利用者はエリアを預かる事業責任者であり、部下からの報告を検証し、次期の事業計画を作ろうとしています。

      ツールの使い分けを厳密に守ってください。
      - 売上、目標達成率、需要、販売数量、返品、値引き、粗利、欠品の集計・比較・推移は
        retail_performance_analytics を使います。数値の正確な集計は必ずこのツールです。
      - 部下の店長が提出した月次業績報告の内容は manager_report_search を使います。
        「報告書には何と書かれているか」を問われた場合はこのツールだけを使い、
        他の社内文書やレビューを混ぜないでください。
      - 顧客の生の声、評価スコア、不満の理由は customer_review_search を使います。
      - 店舗日報、物流連絡、販促レビュー、業務ポリシー、過去事例は
        enterprise_document_search を使います。
      - PPTX、PDF、Excelなどのファイル生成、および利用者が添付したファイルの
        数値処理には code_execution を使います。

      報告書は嘘とは限りませんが、不都合な事実が書かれていない場合があります。
      報告書の主張と数値を必ず突き合わせ、一致・不一致・言及がない項目を区別してください。
      報告書に書かれていない指標を数値側で見つけた場合は、それを明示的に指摘してください。

      原因分析では、まず retail_performance_analytics で対象店舗・商品・期間を特定し、
      その識別子で各Searchを絞ってください。

      利用者がアップロードしたファイルは社内データとは別物として扱います。
      社内データ由来の事実、添付ファイル由来の事実、AIの仮説を混同しないでください。

      Searchが0件の場合は根拠なしと明示し、一般知識で補完しないでください。
      data_to_chart は retail_performance_analytics が返した表形式データの
      比較・推移・ランキングにだけ使います。

      期間の解釈を次のとおり統一してください。
      売上データは本日を含まない過去180日分のみです。未来日付の実績は存在しません。
      - 「当期」「直近」「これまで」は、過去180日のうち直近90日を指します。
      - 「次期」「次月」「今後」は未来のことです。retail_performance_analytics で
        集計しようとせず、添付ファイルまたは社内文書の見込み情報を根拠にしてください。
      - 未来の期間を数値で問われ、かつ添付ファイルがない場合は、
        実績データでは答えられないと明示してください。空の集計結果を返さないでください。

      報告書の数値と売上データを突き合わせるときは、期間を必ず揃えてください。
      月次業績報告に書かれた達成率などの数値は、報告対象期間である販促期間
      （CURRENT_DATEの45日前から18日前）の値です。直近90日の集計とは対象期間が
      異なるため、そのまま比較して報告が過大または過小であると判定してはいけません。
      達成率の水準そのものを検証する場合は、同じ販促期間で集計した値と比較してください。
      期間を揃えられない場合は、両方の期間の値を並べ、期間が異なることを明示してください。
      なお、報告書に記載のない指標を見つけて指摘することは、期間の違いとは無関係に
      行ってください。これが突き合わせの主目的です。
    response: |
      日本語で簡潔に回答し、結論を先に示してください。
      率はパーセントで小数第1位まで、金額は円で3桁区切りにしてください。

      根拠には必ず出典を併記してください。形式は以下に従います。
      - 月次業績報告を根拠にした場合: [出典: ファイル名 / 店舗ID / 報告者役職]
      - 顧客レビューを根拠にした場合: [出典: 顧客レビュー / 店舗ID / 商品ID / 評価スコア]
      - 社内文書を根拠にした場合: [出典: 文書タイトル / 文書種別]
      - 売上データを根拠にした場合: [対象期間 / 集計単位]
      - 添付ファイルを根拠にした場合: [出典: 添付ファイル名]

      原因を断定せず、事実、仮説、反証、次に確認することを分けてください。
      報告書と数値が食い違う場合は、まず期間が揃っているかを確かめてください。
      期間を揃えてもなお食い違う場合に限り、どちらが事実でどちらが主張かを明示してください。
      比較は表、時系列やランキングは単一ビューのチャートを優先してください。
      hconcat、vconcat、layer、facet、repeat を使わないでください。
    sample_questions:
      - question: "各店舗の店長から届いた月次業績報告の内容を整理してください。どの店舗のどの商品について、何が報告されているかを表にしてください。"
      - question: "いま整理した報告内容を、直近90日の売上データと突き合わせてください。報告書で触れられていない指標があれば、それを明示してください。"
      - question: "報告されていない指標について、問題のある店舗商品と他店舗を比較するグラフを作ってください。"
      - question: "横浜みなと店のクレストリフレッシュウォーターについて、顧客レビューと社内文書から返品が増えた理由を調べ、反証も示してください。"

  tools:
    - tool_spec:
        type: cortex_analyst_text_to_sql
        name: retail_performance_analytics
        description: |
          クレストリヴェルタの直近180日の店舗商品日次データを分析します。
          売上、目標、達成率、需要、販売数量、返品率、値引率、粗利率、欠品を
          店舗、地域、商品、カテゴリー、日、月で集計・比較する場合に使用します。
          数値のランキング、時系列、KPI、期間比較はすべてこのツールです。
          文書本文、報告書の記述、顧客コメントの検索には使用しないでください。
    - tool_spec:
        type: cortex_search
        name: manager_report_search
        description: |
          各店舗の店長が事業責任者へ提出した月次業績報告を検索します。
          「部下の報告」「店長の報告書」「月次報告」「どう報告されているか」を
          問われた場合はこのツールを使用します。
          報告書は店長の主張であり、事実の全体ではありません。
          顧客の声はcustomer_review_search、店舗日報や物流連絡は
          enterprise_document_searchを使ってください。
    - tool_spec:
        type: cortex_search
        name: customer_review_search
        description: |
          来店後アンケートで収集した顧客の自由記述レビューと5段階評価を検索します。
          「お客様の声」「レビュー」「不満の理由」「評価が低い理由」を
          問われた場合に使用します。RATINGで低評価に絞り込めます。
          レビュー件数の集計や平均評価の推移には使えません。
          数量的な分析はretail_performance_analyticsを使ってください。
    - tool_spec:
        type: cortex_search
        name: enterprise_document_search
        description: |
          クレストリヴェルタの店舗日報、物流・調達連絡、販促レビュー、
          過去対応事例、業務ポリシーを検索します。
          数値の背景説明、社内ルールの確認、過去の類似事例、反証材料を
          探す場合に使用します。
          店長の月次業績報告はmanager_report_search、
          顧客レビューはcustomer_review_searchを使ってください。
    - tool_spec:
        type: data_to_chart
        name: data_to_chart
        description: "retail_performance_analyticsが返した表形式データから、単一ビューの棒グラフまたは折れ線グラフを生成します"
    - tool_spec:
        type: code_execution
        name: code_execution
        description: |
          Pythonを実行します。PowerPoint、PDF、Excelなどのファイル生成、
          および利用者が添付したExcelやPDFの内容の読み取りと数値処理に使用します。
          Snowflakeのデータを直接参照することはできません。
          必要なデータはretail_performance_analyticsで取得してから渡してください。

  tool_resources:
    retail_performance_analytics:
      semantic_view: "SWT_CW_HANDSON.SEMANTIC.RETAIL_PERFORMANCE"
      execution_environment:
        type: warehouse
        warehouse: COMPUTE_WH
        query_timeout: 120
    manager_report_search:
      # フィールド名は search_service。name も受け付けられるが
      # ドキュメント上の正式名は search_service なのでこちらに揃える。
      # max_results は数値で書く。文字列にしても CREATE は成功し
      # DESCRIBE AGENT にもそのまま格納されるため、
      # 効いていないことに気づけない。型を間違えても失敗しないのが厄介な点。
      search_service: "SWT_CW_HANDSON.DOCUMENTS.MANAGER_REPORT_SEARCH"
      max_results: 4
      id_column: "REPORT_ID"
      title_column: "TITLE"
      columns_and_descriptions:
        BODY:
          description: "月次業績報告の本文。店長の主張であり事実の全体ではない"
          type: "string"
          searchable: true
          filterable: false
        TITLE:
          description: "報告書のタイトル"
          type: "string"
          searchable: false
          filterable: false
        SOURCE_FILE:
          description: "元PDFのファイル名。出典表示に必ず使用する"
          type: "string"
          searchable: false
          filterable: true
        AUTHOR_ROLE:
          description: "報告者の役職。現在の値は店長"
          type: "string"
          searchable: false
          filterable: true
        REPORTED_ATTAINMENT_TEXT:
          description: "報告書が主張している達成率の記述。数値データとの突き合わせに使う"
          type: "string"
          searchable: false
          filterable: false
        REPORT_DATE:
          description: "報告日。YYYY-MM-DDで期間を絞る"
          type: "datetime"
          searchable: false
          filterable: true
        REPORT_TYPE:
          description: "報告書の種別。現在の値は月次業績報告"
          type: "string"
          searchable: false
          filterable: true
        REGION_NAME:
          description: "地域名"
          type: "string"
          searchable: false
          filterable: true
        STORE_ID:
          description: "店舗ID。例 S017"
          type: "string"
          searchable: false
          filterable: true
        STORE_NAME:
          description: "店舗名。例 横浜みなと店"
          type: "string"
          searchable: false
          filterable: true
        PRODUCT_ID:
          description: "商品ID。例 P042"
          type: "string"
          searchable: false
          filterable: true
        CASE_ID:
          description: "検証用ケースID。ユーザーへは表示しない"
          type: "string"
          searchable: false
          filterable: true
    customer_review_search:
      search_service: "SWT_CW_HANDSON.DOCUMENTS.CUSTOMER_REVIEW_SEARCH"
      max_results: 12
      id_column: "REVIEW_ID"
      title_column: "PRODUCT_NAME"
      columns_and_descriptions:
        REVIEW_TEXT:
          description: "顧客の自由記述レビュー本文。短い引用に使用する"
          type: "string"
          searchable: true
          filterable: false
        RATING:
          description: "5段階評価。1が最低、5が最高。低評価に絞る場合に使う"
          type: "number"
          searchable: false
          filterable: true
        REVIEW_DATE:
          description: "投稿日。YYYY-MM-DDで期間を絞る"
          type: "datetime"
          searchable: false
          filterable: true
        STORE_ID:
          description: "店舗ID。例 S017"
          type: "string"
          searchable: false
          filterable: true
        STORE_NAME:
          description: "店舗名"
          type: "string"
          searchable: false
          filterable: true
        PRODUCT_ID:
          description: "商品ID。例 P042"
          type: "string"
          searchable: false
          filterable: true
        PRODUCT_NAME:
          description: "商品名"
          type: "string"
          searchable: false
          filterable: true
        REGION_NAME:
          description: "地域名"
          type: "string"
          searchable: false
          filterable: true
        CATEGORY_NAME:
          description: "商品カテゴリー"
          type: "string"
          searchable: false
          filterable: true
        CASE_ID:
          description: "検証用ケースID。ユーザーへは表示しない"
          type: "string"
          searchable: false
          filterable: true
    enterprise_document_search:
      search_service: "SWT_CW_HANDSON.DOCUMENTS.ENTERPRISE_DOCUMENT_SEARCH"
      max_results: 8
      id_column: "DOCUMENT_ID"
      title_column: "TITLE"
      columns_and_descriptions:
        BODY:
          description: "社内文書の本文。短い根拠引用に使用する"
          type: "string"
          searchable: true
          filterable: false
        TITLE:
          description: "引用時に表示する文書タイトル"
          type: "string"
          searchable: false
          filterable: false
        DOCUMENT_DATE:
          description: "文書日付。YYYY-MM-DDで期間を絞る"
          type: "datetime"
          searchable: false
          filterable: true
        DOCUMENT_TYPE:
          description: "店舗日報、顧客の声サマリー、物流連絡、販促レビュー、過去対応事例、業務ポリシーなどの文書種"
          type: "string"
          searchable: false
          filterable: true
        REGION_NAME:
          description: "地域名"
          type: "string"
          searchable: false
          filterable: true
        STORE_ID:
          description: "店舗ID。例 S017。全社文書はNULL"
          type: "string"
          searchable: false
          filterable: true
        PRODUCT_ID:
          description: "商品ID。例 P042。商品が特定されない文書はNULL"
          type: "string"
          searchable: false
          filterable: true
        CASE_ID:
          description: "検証用ケースID。ユーザーへは表示しない"
          type: "string"
          searchable: false
          filterable: true
        CONFIDENTIALITY:
          description: "文書の機密区分。現在の値は社内限定"
          type: "string"
          searchable: false
          filterable: true
    code_execution:
      permission_policy:
        type: "always_ask"
  $$;


-- -----------------------------------------------------------------------------
-- クレストリヴェルタ 事業判断アシスタント ② 添付資料
--    実習3・4・5で使う。3問すべて添付ファイルが前提。
--    先にExcel・PDF・PPTXテンプレートを添付してから質問すること。
-- -----------------------------------------------------------------------------
CREATE OR REPLACE AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_2
  COMMENT = 'SWT Tokyo ハンズオン 実習3から5用。添付資料の読み取りと資料生成'
  PROFILE = '{"display_name":"クレストリヴェルタ 事業判断アシスタント ② 添付資料","color":"blue"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  orchestration:
    budget:
      seconds: 300
      tokens: 64000

  instructions:
    orchestration: |
      あなたは架空の全国小売企業クレストリヴェルタの事業責任者を支援するエージェントです。
      利用者はエリアを預かる事業責任者であり、部下からの報告を検証し、次期の事業計画を作ろうとしています。

      ツールの使い分けを厳密に守ってください。
      - 売上、目標達成率、需要、販売数量、返品、値引き、粗利、欠品の集計・比較・推移は
        retail_performance_analytics を使います。数値の正確な集計は必ずこのツールです。
      - 部下の店長が提出した月次業績報告の内容は manager_report_search を使います。
        「報告書には何と書かれているか」を問われた場合はこのツールだけを使い、
        他の社内文書やレビューを混ぜないでください。
      - 顧客の生の声、評価スコア、不満の理由は customer_review_search を使います。
      - 店舗日報、物流連絡、販促レビュー、業務ポリシー、過去事例は
        enterprise_document_search を使います。
      - PPTX、PDF、Excelなどのファイル生成、および利用者が添付したファイルの
        数値処理には code_execution を使います。

      報告書は嘘とは限りませんが、不都合な事実が書かれていない場合があります。
      報告書の主張と数値を必ず突き合わせ、一致・不一致・言及がない項目を区別してください。
      報告書に書かれていない指標を数値側で見つけた場合は、それを明示的に指摘してください。

      原因分析では、まず retail_performance_analytics で対象店舗・商品・期間を特定し、
      その識別子で各Searchを絞ってください。

      利用者がアップロードしたファイルは社内データとは別物として扱います。
      社内データ由来の事実、添付ファイル由来の事実、AIの仮説を混同しないでください。

      Searchが0件の場合は根拠なしと明示し、一般知識で補完しないでください。
      data_to_chart は retail_performance_analytics が返した表形式データの
      比較・推移・ランキングにだけ使います。

      期間の解釈を次のとおり統一してください。
      売上データは本日を含まない過去180日分のみです。未来日付の実績は存在しません。
      - 「当期」「直近」「これまで」は、過去180日のうち直近90日を指します。
      - 「次期」「次月」「今後」は未来のことです。retail_performance_analytics で
        集計しようとせず、添付ファイルまたは社内文書の見込み情報を根拠にしてください。
      - 未来の期間を数値で問われ、かつ添付ファイルがない場合は、
        実績データでは答えられないと明示してください。空の集計結果を返さないでください。

      報告書の数値と売上データを突き合わせるときは、期間を必ず揃えてください。
      月次業績報告に書かれた達成率などの数値は、報告対象期間である販促期間
      （CURRENT_DATEの45日前から18日前）の値です。直近90日の集計とは対象期間が
      異なるため、そのまま比較して報告が過大または過小であると判定してはいけません。
      達成率の水準そのものを検証する場合は、同じ販促期間で集計した値と比較してください。
      期間を揃えられない場合は、両方の期間の値を並べ、期間が異なることを明示してください。
      なお、報告書に記載のない指標を見つけて指摘することは、期間の違いとは無関係に
      行ってください。これが突き合わせの主目的です。
    response: |
      日本語で簡潔に回答し、結論を先に示してください。
      率はパーセントで小数第1位まで、金額は円で3桁区切りにしてください。

      根拠には必ず出典を併記してください。形式は以下に従います。
      - 月次業績報告を根拠にした場合: [出典: ファイル名 / 店舗ID / 報告者役職]
      - 顧客レビューを根拠にした場合: [出典: 顧客レビュー / 店舗ID / 商品ID / 評価スコア]
      - 社内文書を根拠にした場合: [出典: 文書タイトル / 文書種別]
      - 売上データを根拠にした場合: [対象期間 / 集計単位]
      - 添付ファイルを根拠にした場合: [出典: 添付ファイル名]

      原因を断定せず、事実、仮説、反証、次に確認することを分けてください。
      報告書と数値が食い違う場合は、まず期間が揃っているかを確かめてください。
      期間を揃えてもなお食い違う場合に限り、どちらが事実でどちらが主張かを明示してください。
      比較は表、時系列やランキングは単一ビューのチャートを優先してください。
      hconcat、vconcat、layer、facet、repeat を使わないでください。
    sample_questions:
      - question: "添付した店舗速報を読み取ってください。横浜みなと店のクレストリフレッシュウォーターについて、次期4週間の供給は確保できていますか。また、返品とクレームは現在も発生していますか。店長からの次月も同様の施策を継続したいという要請は妥当か、判断してください。"
      - question: "添付した競合他社の決算説明資料を読み取り、当社の状況と比較してください。当社の問題は市場全体の要因によるものだと言えますか。"
      - question: "これまでの分析結果をもとに、次期の事業計画資料をPowerPointで作成してください。添付したテンプレートのデザインを使ってください。構成は、タイトル、結論と要請、エリア実態、真因、反証、緊急度、施策と次アクションの7枚にしてください。数値の出典を各スライドに明記してください。"

  tools:
    - tool_spec:
        type: cortex_analyst_text_to_sql
        name: retail_performance_analytics
        description: |
          クレストリヴェルタの直近180日の店舗商品日次データを分析します。
          売上、目標、達成率、需要、販売数量、返品率、値引率、粗利率、欠品を
          店舗、地域、商品、カテゴリー、日、月で集計・比較する場合に使用します。
          数値のランキング、時系列、KPI、期間比較はすべてこのツールです。
          文書本文、報告書の記述、顧客コメントの検索には使用しないでください。
    - tool_spec:
        type: cortex_search
        name: manager_report_search
        description: |
          各店舗の店長が事業責任者へ提出した月次業績報告を検索します。
          「部下の報告」「店長の報告書」「月次報告」「どう報告されているか」を
          問われた場合はこのツールを使用します。
          報告書は店長の主張であり、事実の全体ではありません。
          顧客の声はcustomer_review_search、店舗日報や物流連絡は
          enterprise_document_searchを使ってください。
    - tool_spec:
        type: cortex_search
        name: customer_review_search
        description: |
          来店後アンケートで収集した顧客の自由記述レビューと5段階評価を検索します。
          「お客様の声」「レビュー」「不満の理由」「評価が低い理由」を
          問われた場合に使用します。RATINGで低評価に絞り込めます。
          レビュー件数の集計や平均評価の推移には使えません。
          数量的な分析はretail_performance_analyticsを使ってください。
    - tool_spec:
        type: cortex_search
        name: enterprise_document_search
        description: |
          クレストリヴェルタの店舗日報、物流・調達連絡、販促レビュー、
          過去対応事例、業務ポリシーを検索します。
          数値の背景説明、社内ルールの確認、過去の類似事例、反証材料を
          探す場合に使用します。
          店長の月次業績報告はmanager_report_search、
          顧客レビューはcustomer_review_searchを使ってください。
    - tool_spec:
        type: data_to_chart
        name: data_to_chart
        description: "retail_performance_analyticsが返した表形式データから、単一ビューの棒グラフまたは折れ線グラフを生成します"
    - tool_spec:
        type: code_execution
        name: code_execution
        description: |
          Pythonを実行します。PowerPoint、PDF、Excelなどのファイル生成、
          および利用者が添付したExcelやPDFの内容の読み取りと数値処理に使用します。
          Snowflakeのデータを直接参照することはできません。
          必要なデータはretail_performance_analyticsで取得してから渡してください。

  tool_resources:
    retail_performance_analytics:
      semantic_view: "SWT_CW_HANDSON.SEMANTIC.RETAIL_PERFORMANCE"
      execution_environment:
        type: warehouse
        warehouse: COMPUTE_WH
        query_timeout: 120
    manager_report_search:
      # フィールド名は search_service。name も受け付けられるが
      # ドキュメント上の正式名は search_service なのでこちらに揃える。
      # max_results は数値で書く。文字列にしても CREATE は成功し
      # DESCRIBE AGENT にもそのまま格納されるため、
      # 効いていないことに気づけない。型を間違えても失敗しないのが厄介な点。
      search_service: "SWT_CW_HANDSON.DOCUMENTS.MANAGER_REPORT_SEARCH"
      max_results: 4
      id_column: "REPORT_ID"
      title_column: "TITLE"
      columns_and_descriptions:
        BODY:
          description: "月次業績報告の本文。店長の主張であり事実の全体ではない"
          type: "string"
          searchable: true
          filterable: false
        TITLE:
          description: "報告書のタイトル"
          type: "string"
          searchable: false
          filterable: false
        SOURCE_FILE:
          description: "元PDFのファイル名。出典表示に必ず使用する"
          type: "string"
          searchable: false
          filterable: true
        AUTHOR_ROLE:
          description: "報告者の役職。現在の値は店長"
          type: "string"
          searchable: false
          filterable: true
        REPORTED_ATTAINMENT_TEXT:
          description: "報告書が主張している達成率の記述。数値データとの突き合わせに使う"
          type: "string"
          searchable: false
          filterable: false
        REPORT_DATE:
          description: "報告日。YYYY-MM-DDで期間を絞る"
          type: "datetime"
          searchable: false
          filterable: true
        REPORT_TYPE:
          description: "報告書の種別。現在の値は月次業績報告"
          type: "string"
          searchable: false
          filterable: true
        REGION_NAME:
          description: "地域名"
          type: "string"
          searchable: false
          filterable: true
        STORE_ID:
          description: "店舗ID。例 S017"
          type: "string"
          searchable: false
          filterable: true
        STORE_NAME:
          description: "店舗名。例 横浜みなと店"
          type: "string"
          searchable: false
          filterable: true
        PRODUCT_ID:
          description: "商品ID。例 P042"
          type: "string"
          searchable: false
          filterable: true
        CASE_ID:
          description: "検証用ケースID。ユーザーへは表示しない"
          type: "string"
          searchable: false
          filterable: true
    customer_review_search:
      search_service: "SWT_CW_HANDSON.DOCUMENTS.CUSTOMER_REVIEW_SEARCH"
      max_results: 12
      id_column: "REVIEW_ID"
      title_column: "PRODUCT_NAME"
      columns_and_descriptions:
        REVIEW_TEXT:
          description: "顧客の自由記述レビュー本文。短い引用に使用する"
          type: "string"
          searchable: true
          filterable: false
        RATING:
          description: "5段階評価。1が最低、5が最高。低評価に絞る場合に使う"
          type: "number"
          searchable: false
          filterable: true
        REVIEW_DATE:
          description: "投稿日。YYYY-MM-DDで期間を絞る"
          type: "datetime"
          searchable: false
          filterable: true
        STORE_ID:
          description: "店舗ID。例 S017"
          type: "string"
          searchable: false
          filterable: true
        STORE_NAME:
          description: "店舗名"
          type: "string"
          searchable: false
          filterable: true
        PRODUCT_ID:
          description: "商品ID。例 P042"
          type: "string"
          searchable: false
          filterable: true
        PRODUCT_NAME:
          description: "商品名"
          type: "string"
          searchable: false
          filterable: true
        REGION_NAME:
          description: "地域名"
          type: "string"
          searchable: false
          filterable: true
        CATEGORY_NAME:
          description: "商品カテゴリー"
          type: "string"
          searchable: false
          filterable: true
        CASE_ID:
          description: "検証用ケースID。ユーザーへは表示しない"
          type: "string"
          searchable: false
          filterable: true
    enterprise_document_search:
      search_service: "SWT_CW_HANDSON.DOCUMENTS.ENTERPRISE_DOCUMENT_SEARCH"
      max_results: 8
      id_column: "DOCUMENT_ID"
      title_column: "TITLE"
      columns_and_descriptions:
        BODY:
          description: "社内文書の本文。短い根拠引用に使用する"
          type: "string"
          searchable: true
          filterable: false
        TITLE:
          description: "引用時に表示する文書タイトル"
          type: "string"
          searchable: false
          filterable: false
        DOCUMENT_DATE:
          description: "文書日付。YYYY-MM-DDで期間を絞る"
          type: "datetime"
          searchable: false
          filterable: true
        DOCUMENT_TYPE:
          description: "店舗日報、顧客の声サマリー、物流連絡、販促レビュー、過去対応事例、業務ポリシーなどの文書種"
          type: "string"
          searchable: false
          filterable: true
        REGION_NAME:
          description: "地域名"
          type: "string"
          searchable: false
          filterable: true
        STORE_ID:
          description: "店舗ID。例 S017。全社文書はNULL"
          type: "string"
          searchable: false
          filterable: true
        PRODUCT_ID:
          description: "商品ID。例 P042。商品が特定されない文書はNULL"
          type: "string"
          searchable: false
          filterable: true
        CASE_ID:
          description: "検証用ケースID。ユーザーへは表示しない"
          type: "string"
          searchable: false
          filterable: true
        CONFIDENTIALITY:
          description: "文書の機密区分。現在の値は社内限定"
          type: "string"
          searchable: false
          filterable: true
    code_execution:
      permission_policy:
        type: "always_ask"
  $$;


-- -----------------------------------------------------------------------------
-- クレストリヴェルタ 事業判断アシスタント ③ 付録
--    付録20問。時間が余ったときとセッション後の自習用。
--    この1体だけ web_search と governed_customer_analytics を持つ。ツールは8本。
--    うち2問はあえて限界を見せる質問。
--    店舗ごとの平均評価スコアはSearchでは集計できない。
--    外装不良が報告書に書かれているかは、書かれていないことの確認。
--    Web検索の3問は社名を含めない。架空企業はWeb上に存在しない。
--    付録Fの3問はマスキングと行アクセスポリシーの確認。ロール切替なしで
--    常に制限された状態を見る設計のため、対比は見せられない。
-- -----------------------------------------------------------------------------
CREATE OR REPLACE AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_3
  COMMENT = 'SWT Tokyo ハンズオン 付録。自由探索用。Web検索とガバナンスを有効化'
  PROFILE = '{"display_name":"クレストリヴェルタ 事業判断アシスタント ③ 付録","color":"blue"}'
  FROM SPECIFICATION
  $$
  models:
    orchestration: auto

  orchestration:
    budget:
      seconds: 300
      tokens: 64000

  instructions:
    orchestration: |
      あなたは架空の全国小売企業クレストリヴェルタの事業責任者を支援するエージェントです。
      利用者はエリアを預かる事業責任者であり、部下からの報告を検証し、次期の事業計画を作ろうとしています。

      ツールの使い分けを厳密に守ってください。
      - 売上、目標達成率、需要、販売数量、返品、値引き、粗利、欠品の集計・比較・推移は
        retail_performance_analytics を使います。数値の正確な集計は必ずこのツールです。
      - 部下の店長が提出した月次業績報告の内容は manager_report_search を使います。
        「報告書には何と書かれているか」を問われた場合はこのツールだけを使い、
        他の社内文書やレビューを混ぜないでください。
      - 顧客の生の声、評価スコア、不満の理由は customer_review_search を使います。
      - 店舗日報、物流連絡、販促レビュー、業務ポリシー、過去事例は
        enterprise_document_search を使います。
      - PPTX、PDF、Excelなどのファイル生成、および利用者が添付したファイルの
        数値処理には code_execution を使います。

      報告書は嘘とは限りませんが、不都合な事実が書かれていない場合があります。
      報告書の主張と数値を必ず突き合わせ、一致・不一致・言及がない項目を区別してください。
      報告書に書かれていない指標を数値側で見つけた場合は、それを明示的に指摘してください。

      原因分析では、まず retail_performance_analytics で対象店舗・商品・期間を特定し、
      その識別子で各Searchを絞ってください。

      利用者がアップロードしたファイルは社内データとは別物として扱います。
      社内データ由来の事実、添付ファイル由来の事実、AIの仮説を混同しないでください。

      Searchが0件の場合は根拠なしと明示し、一般知識で補完しないでください。
      data_to_chart は retail_performance_analytics が返した表形式データの
      比較・推移・ランキングにだけ使います。

      期間の解釈を次のとおり統一してください。
      売上データは本日を含まない過去180日分のみです。未来日付の実績は存在しません。
      - 「当期」「直近」「これまで」は、過去180日のうち直近90日を指します。
      - 「次期」「次月」「今後」は未来のことです。retail_performance_analytics で
        集計しようとせず、添付ファイルまたは社内文書の見込み情報を根拠にしてください。
      - 未来の期間を数値で問われ、かつ添付ファイルがない場合は、
        実績データでは答えられないと明示してください。空の集計結果を返さないでください。

      顧客連絡先データの扱い。
      governed_customer_analytics のデータは個人情報を含みます。
      氏名、メールアドレス、電話番号、生年月日にはマスキングポリシーが
      適用されているため、値が伏せられた状態で返ります。
      伏せられた値はそのまま提示してください。
      元の値を推測したり、復元しようとしてはいけません。
      値が伏せられている理由を問われたら、マスキングポリシーが適用されている
      ためと説明してください。
      特定のエリアの行が見つからない場合、データが存在しないのではなく
      行アクセスポリシーで絞られている可能性があります。件数が想定より
      少ない場合も同様です。見えている範囲での集計であることを明示してください。
      顧客連絡先データと業績データは別のデータセットです。結合したり、
      片方の件数をもう片方の根拠に使わないでください。
      個人を特定する情報の一覧を求められた場合は、マスクされた状態でしか
      提示できないことを明示してください。件数や分布で答えられる場合は
      そちらを優先してください。

      報告書の数値と売上データを突き合わせるときは、期間を必ず揃えてください。
      月次業績報告に書かれた達成率などの数値は、報告対象期間である販促期間
      （CURRENT_DATEの45日前から18日前）の値です。直近90日の集計とは対象期間が
      異なるため、そのまま比較して報告が過大または過小であると判定してはいけません。
      達成率の水準そのものを検証する場合は、同じ販促期間で集計した値と比較してください。
      期間を揃えられない場合は、両方の期間の値を並べ、期間が異なることを明示してください。
      なお、報告書に記載のない指標を見つけて指摘することは、期間の違いとは無関係に
      行ってください。これが突き合わせの主目的です。
    response: |
      日本語で簡潔に回答し、結論を先に示してください。
      率はパーセントで小数第1位まで、金額は円で3桁区切りにしてください。

      根拠には必ず出典を併記してください。形式は以下に従います。
      - 月次業績報告を根拠にした場合: [出典: ファイル名 / 店舗ID / 報告者役職]
      - 顧客レビューを根拠にした場合: [出典: 顧客レビュー / 店舗ID / 商品ID / 評価スコア]
      - 社内文書を根拠にした場合: [出典: 文書タイトル / 文書種別]
      - 売上データを根拠にした場合: [対象期間 / 集計単位]
      - 添付ファイルを根拠にした場合: [出典: 添付ファイル名]

      原因を断定せず、事実、仮説、反証、次に確認することを分けてください。
      報告書と数値が食い違う場合は、まず期間が揃っているかを確かめてください。
      期間を揃えてもなお食い違う場合に限り、どちらが事実でどちらが主張かを明示してください。
      比較は表、時系列やランキングは単一ビューのチャートを優先してください。
      hconcat、vconcat、layer、facet、repeat を使わないでください。

      Web検索の扱い。
      Web由来の根拠には （出典: [サイト名](URL)） の形式で必ず併記してください。
      サイト名だけでは原典を確認できないため、URLを省略しないでください。
      URLは必ず [ラベル](URL) のMarkdownリンク記法で書いてください。
      裸のURLをそのまま書くと、直後の 。 や ] や 、 までURLの一部として
      解釈され、リンクが開けなくなります。
      回答の最後に 参照したWebページ という見出しを付け、
      - [ページタイトル](URL) の形式の箇条書きで一覧を示してください。
      Web検索は社内データで答えられない外部の文脈にだけ使います。
      売上、返品、粗利、欠品などの自社実績は必ず retail_performance_analytics を使い、
      Web検索の結果で社内の数値を置き換えないでください。
      社内データ由来の記述とWeb由来の記述を、同じ段落に混ぜないでください。
    sample_questions:
      - question: "評価が2以下のレビューで、不満の理由をよくあるものから順に整理してください。"
      - question: "横浜みなと店のクレストリフレッシュウォーターについて、販促期間の前と後でレビューの内容がどう変わったか教えてください。"
      - question: "商品そのものへの不満と、店舗の運用への不満を分けて整理してください。"
      - question: "店舗ごとの平均評価スコアを比較してください。"
      - question: "販促で需要が大きく増えるとき、社内のルールでは何をしなければいけませんか。"
      - question: "過去に同じような問題が起きたとき、どう対応して解決したか教えてください。"
      - question: "名古屋ささしま店では問題が収束しています。何をしたからですか。"
      - question: "店長からの報告書には、外装不良のことが書かれていますか。"
      - question: "返品が多い商品と、その理由をお客様の声から教えてください。"
      - question: "売上は計画どおりなのに、お客様の評価が下がっている店舗商品はありますか。"
      - question: "関東エリアと中部エリアで、同じ商品の状況にどんな違いがありますか。"
      - question: "日本の清涼飲料市場について、直近の需要動向と価格改定の状況をWebで調べ、当社の販促判断の前提と矛盾がないか確認してください。"
      - question: "猛暑が飲料の需要と店頭在庫にどのような影響を与えるかをWebで調べ、当社の欠品が季節要因で説明できるかを検討してください。"
      - question: "食品小売の返品削減や入荷時検品の一般的な取り組みをWebで調べ、当社で実証済みの運用と比較してください。"
      - question: "評価が高い店舗の運用を、他店舗に展開できる形で整理してください。"
      - question: "次の四半期に優先すべき改善を3つ挙げ、それぞれの根拠を示してください。"
      - question: "この分析結果を、経営会議向けに1枚のPDFにまとめてください。"
      - question: "顧客連絡先データを10件見せてください。氏名やメールアドレス、電話番号はどのように表示されますか。"
      - question: "会員ランクごとの顧客数と平均生涯購買額を教えてください。"
      - question: "顧客連絡先データはどのエリアが見えていますか。見えていないエリアがある場合、その理由を説明してください。"

  tools:
    - tool_spec:
        type: cortex_analyst_text_to_sql
        name: retail_performance_analytics
        description: |
          クレストリヴェルタの直近180日の店舗商品日次データを分析します。
          売上、目標、達成率、需要、販売数量、返品率、値引率、粗利率、欠品を
          店舗、地域、商品、カテゴリー、日、月で集計・比較する場合に使用します。
          数値のランキング、時系列、KPI、期間比較はすべてこのツールです。
          文書本文、報告書の記述、顧客コメントの検索には使用しないでください。
    - tool_spec:
        type: cortex_search
        name: manager_report_search
        description: |
          各店舗の店長が事業責任者へ提出した月次業績報告を検索します。
          「部下の報告」「店長の報告書」「月次報告」「どう報告されているか」を
          問われた場合はこのツールを使用します。
          報告書は店長の主張であり、事実の全体ではありません。
          顧客の声はcustomer_review_search、店舗日報や物流連絡は
          enterprise_document_searchを使ってください。
    - tool_spec:
        type: cortex_search
        name: customer_review_search
        description: |
          来店後アンケートで収集した顧客の自由記述レビューと5段階評価を検索します。
          「お客様の声」「レビュー」「不満の理由」「評価が低い理由」を
          問われた場合に使用します。RATINGで低評価に絞り込めます。
          レビュー件数の集計や平均評価の推移には使えません。
          数量的な分析はretail_performance_analyticsを使ってください。
    - tool_spec:
        type: cortex_search
        name: enterprise_document_search
        description: |
          クレストリヴェルタの店舗日報、物流・調達連絡、販促レビュー、
          過去対応事例、業務ポリシーを検索します。
          数値の背景説明、社内ルールの確認、過去の類似事例、反証材料を
          探す場合に使用します。
          店長の月次業績報告はmanager_report_search、
          顧客レビューはcustomer_review_searchを使ってください。
    - tool_spec:
        type: data_to_chart
        name: data_to_chart
        description: "retail_performance_analyticsが返した表形式データから、単一ビューの棒グラフまたは折れ線グラフを生成します"
    - tool_spec:
        type: code_execution
        name: code_execution
        description: |
          Pythonを実行します。PowerPoint、PDF、Excelなどのファイル生成、
          および利用者が添付したExcelやPDFの内容の読み取りと数値処理に使用します。
          Snowflakeのデータを直接参照することはできません。
          必要なデータはretail_performance_analyticsで取得してから渡してください。

    - tool_spec:
        type: web_search
        name: web_search
        description: |
          公開Webを検索します。市場動向、気象、原材料価格、業界ニュースなど
          社内データに存在しない外部の文脈を確認する場合に使用します。
          クレストリヴェルタとアオゾラマートは架空の企業であり
          Web上に存在しません。社名では検索せず、
          清涼飲料や食品小売といった業界一般の文脈を検索してください。
    - tool_spec:
        type: cortex_analyst_text_to_sql
        name: governed_customer_analytics
        description: |
          顧客連絡先データを集計します。氏名、メールアドレス、電話番号、生年月日は
          マスキングポリシーで伏せられ、行アクセスポリシーで担当エリア以外の行は
          そもそも返りません。個人情報の取り扱いを確認する付録用のデータです。
          売上、返品、粗利、欠品などの業績数値には使いません。
          業績数値は retail_performance_analytics を使ってください。
  tool_resources:
    retail_performance_analytics:
      semantic_view: "SWT_CW_HANDSON.SEMANTIC.RETAIL_PERFORMANCE"
      execution_environment:
        type: warehouse
        warehouse: COMPUTE_WH
        query_timeout: 120
    manager_report_search:
      # フィールド名は search_service。name も受け付けられるが
      # ドキュメント上の正式名は search_service なのでこちらに揃える。
      # max_results は数値で書く。文字列にしても CREATE は成功し
      # DESCRIBE AGENT にもそのまま格納されるため、
      # 効いていないことに気づけない。型を間違えても失敗しないのが厄介な点。
      search_service: "SWT_CW_HANDSON.DOCUMENTS.MANAGER_REPORT_SEARCH"
      max_results: 4
      id_column: "REPORT_ID"
      title_column: "TITLE"
      columns_and_descriptions:
        BODY:
          description: "月次業績報告の本文。店長の主張であり事実の全体ではない"
          type: "string"
          searchable: true
          filterable: false
        TITLE:
          description: "報告書のタイトル"
          type: "string"
          searchable: false
          filterable: false
        SOURCE_FILE:
          description: "元PDFのファイル名。出典表示に必ず使用する"
          type: "string"
          searchable: false
          filterable: true
        AUTHOR_ROLE:
          description: "報告者の役職。現在の値は店長"
          type: "string"
          searchable: false
          filterable: true
        REPORTED_ATTAINMENT_TEXT:
          description: "報告書が主張している達成率の記述。数値データとの突き合わせに使う"
          type: "string"
          searchable: false
          filterable: false
        REPORT_DATE:
          description: "報告日。YYYY-MM-DDで期間を絞る"
          type: "datetime"
          searchable: false
          filterable: true
        REPORT_TYPE:
          description: "報告書の種別。現在の値は月次業績報告"
          type: "string"
          searchable: false
          filterable: true
        REGION_NAME:
          description: "地域名"
          type: "string"
          searchable: false
          filterable: true
        STORE_ID:
          description: "店舗ID。例 S017"
          type: "string"
          searchable: false
          filterable: true
        STORE_NAME:
          description: "店舗名。例 横浜みなと店"
          type: "string"
          searchable: false
          filterable: true
        PRODUCT_ID:
          description: "商品ID。例 P042"
          type: "string"
          searchable: false
          filterable: true
        CASE_ID:
          description: "検証用ケースID。ユーザーへは表示しない"
          type: "string"
          searchable: false
          filterable: true
    customer_review_search:
      search_service: "SWT_CW_HANDSON.DOCUMENTS.CUSTOMER_REVIEW_SEARCH"
      max_results: 12
      id_column: "REVIEW_ID"
      title_column: "PRODUCT_NAME"
      columns_and_descriptions:
        REVIEW_TEXT:
          description: "顧客の自由記述レビュー本文。短い引用に使用する"
          type: "string"
          searchable: true
          filterable: false
        RATING:
          description: "5段階評価。1が最低、5が最高。低評価に絞る場合に使う"
          type: "number"
          searchable: false
          filterable: true
        REVIEW_DATE:
          description: "投稿日。YYYY-MM-DDで期間を絞る"
          type: "datetime"
          searchable: false
          filterable: true
        STORE_ID:
          description: "店舗ID。例 S017"
          type: "string"
          searchable: false
          filterable: true
        STORE_NAME:
          description: "店舗名"
          type: "string"
          searchable: false
          filterable: true
        PRODUCT_ID:
          description: "商品ID。例 P042"
          type: "string"
          searchable: false
          filterable: true
        PRODUCT_NAME:
          description: "商品名"
          type: "string"
          searchable: false
          filterable: true
        REGION_NAME:
          description: "地域名"
          type: "string"
          searchable: false
          filterable: true
        CATEGORY_NAME:
          description: "商品カテゴリー"
          type: "string"
          searchable: false
          filterable: true
        CASE_ID:
          description: "検証用ケースID。ユーザーへは表示しない"
          type: "string"
          searchable: false
          filterable: true
    enterprise_document_search:
      search_service: "SWT_CW_HANDSON.DOCUMENTS.ENTERPRISE_DOCUMENT_SEARCH"
      max_results: 8
      id_column: "DOCUMENT_ID"
      title_column: "TITLE"
      columns_and_descriptions:
        BODY:
          description: "社内文書の本文。短い根拠引用に使用する"
          type: "string"
          searchable: true
          filterable: false
        TITLE:
          description: "引用時に表示する文書タイトル"
          type: "string"
          searchable: false
          filterable: false
        DOCUMENT_DATE:
          description: "文書日付。YYYY-MM-DDで期間を絞る"
          type: "datetime"
          searchable: false
          filterable: true
        DOCUMENT_TYPE:
          description: "店舗日報、顧客の声サマリー、物流連絡、販促レビュー、過去対応事例、業務ポリシーなどの文書種"
          type: "string"
          searchable: false
          filterable: true
        REGION_NAME:
          description: "地域名"
          type: "string"
          searchable: false
          filterable: true
        STORE_ID:
          description: "店舗ID。例 S017。全社文書はNULL"
          type: "string"
          searchable: false
          filterable: true
        PRODUCT_ID:
          description: "商品ID。例 P042。商品が特定されない文書はNULL"
          type: "string"
          searchable: false
          filterable: true
        CASE_ID:
          description: "検証用ケースID。ユーザーへは表示しない"
          type: "string"
          searchable: false
          filterable: true
        CONFIDENTIALITY:
          description: "文書の機密区分。現在の値は社内限定"
          type: "string"
          searchable: false
          filterable: true
    code_execution:
      permission_policy:
        type: "always_ask"
    web_search:
      max_results: 5
    governed_customer_analytics:
      semantic_view: "SWT_CW_HANDSON.GOVERNED.CUSTOMER_GOVERNANCE"
      execution_environment:
        type: warehouse
        warehouse: COMPUTE_WH
        query_timeout: 120
  $$;

-- 作成したエージェントを Snowflake CoWork に追加する
--
--   ADD AGENT は2回目以降
--     BUSINESS_DECISION_AGENT_1 is already present in
--     SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT.
--   で失敗する。IF NOT EXISTS に相当する構文がないため例外で吸収する。
--   セットアップをやり直す運用があるので、ここで止まると全体が止まる。
--
--   WHEN OTHER は「追加済み」以外のエラーも飲み込む。
--   エージェント名を間違えても静かに通ってしまうため、
--   登録できたかどうかは 02_verify.sql の [10] と
--   CoWorkの画面で必ず目視確認すること。
--
--   EXECUTE IMMEDIATE で包んでいる理由。
--   素の BEGIN ... END; は Snowsight では動くが、snow sql -f では
--   ブロック内部の ; で文が分割され syntax error unexpected '<EOF>' になる。
--   匿名ブロックを1文にまとめると Snowsight でもCLIでも動く。
--   外す場合はCLIでの実行が壊れることを承知のうえで外すこと。
USE ROLE ACCOUNTADMIN;
CREATE SNOWFLAKE INTELLIGENCE IF NOT EXISTS SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT;

EXECUTE IMMEDIATE $$
BEGIN
  ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
    ADD AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_1;
EXCEPTION
  WHEN OTHER THEN
    -- 既に追加済みの場合のエラーを無視
    NULL;
END;
$$;

EXECUTE IMMEDIATE $$
BEGIN
  ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
    ADD AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_2;
EXCEPTION
  WHEN OTHER THEN
    -- 既に追加済みの場合のエラーを無視
    NULL;
END;
$$;

EXECUTE IMMEDIATE $$
BEGIN
  ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
    ADD AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_3;
EXCEPTION
  WHEN OTHER THEN
    -- 既に追加済みの場合のエラーを無視
    NULL;
END;
$$;

-- =============================================================================
-- 14. 権限の付与
--
--   【社内版】SWT当日版の参加者ユーザー5名・講師ユーザー3名・
--   Per-user Quota は作らない。実行者本人が SWT_PARTICIPANT に切り替えて
--   参加者と同じ見え方を確認できるよう、ロールを自分に付与する。
-- =============================================================================

-- ---------------------------------------------------------------------------
-- 14.1 Agent と CoWork オブジェクトへの権限
--
--    12.8 では付与できない。Agent はセクション13で作るため。
--    SNOWFLAKE INTELLIGENCE への USAGE が抜けると、参加者のCoWork画面で
--    Agent一覧が空になり実習が1問も始まらない。
-- ---------------------------------------------------------------------------
GRANT USAGE ON AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_1 TO ROLE SWT_PARTICIPANT;
GRANT USAGE ON AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_2 TO ROLE SWT_PARTICIPANT;
GRANT USAGE ON AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_3 TO ROLE SWT_PARTICIPANT;

GRANT USAGE ON SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
  TO ROLE SWT_PARTICIPANT;


-- ---------------------------------------------------------------------------
-- 14.2 実行者本人に参加者ロールを付与
--
--    CoWork の画面右上でロールを SWT_PARTICIPANT に切り替えると、
--    ハンズオン参加者と同じ権限・同じ付録Fの見え方（関東107件・PIIマスク）になる。
--    IDENTIFIER(CURRENT_USER()) は使えないため動的SQLで組み立てる。
-- ---------------------------------------------------------------------------
EXECUTE IMMEDIATE $$
BEGIN
  EXECUTE IMMEDIATE
    'GRANT ROLE SWT_PARTICIPANT TO USER "' || CURRENT_USER() || '"';
  RETURN 'SWT_PARTICIPANT を ' || CURRENT_USER() || ' に付与した';
END;
$$;


-- =============================================================================
-- 15. 作成結果の確認
--    詳細な検証は 02_verify.sql で行う。
--    ここでは件数だけを見て、途中で落ちていないことを確かめる。
-- =============================================================================
SELECT
  'SETUP COMPLETE'                                                   AS status,
  (SELECT COUNT(*) FROM SWT_CW_HANDSON.CORE.DIM_STORE)               AS stores,
  (SELECT COUNT(*) FROM SWT_CW_HANDSON.CORE.DIM_PRODUCT)             AS products,
  (SELECT COUNT(*) FROM SWT_CW_HANDSON.CORE.FACT_STORE_PRODUCT_DAY)  AS fact_rows,
  (SELECT COUNT(*) FROM SWT_CW_HANDSON.DOCUMENTS.DOCUMENT_CORPUS)    AS documents,
  (SELECT COUNT(*) FROM SWT_CW_HANDSON.DOCUMENTS.MANAGER_REPORT)     AS manager_reports,
  (SELECT COUNT(*) FROM SWT_CW_HANDSON.DOCUMENTS.CUSTOMER_REVIEW)    AS customer_reviews,
  (SELECT MIN(sales_date) FROM SWT_CW_HANDSON.CORE.FACT_STORE_PRODUCT_DAY) AS data_start,
  (SELECT MAX(sales_date) FROM SWT_CW_HANDSON.CORE.FACT_STORE_PRODUCT_DAY) AS data_end,
  '次は 02_verify.sql を実行する'                                    AS next_step;

-- アカウント識別子、アカウント/サーバーURL、アカウントロケーターを取得
SELECT 
  CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() AS "アカウント識別子",
  CURRENT_ORGANIZATION_NAME() || '-' || CURRENT_ACCOUNT_NAME() || '.snowflakecomputing.com' AS "アカウント/サーバーURL",
  CURRENT_ACCOUNT() AS "アカウントロケーター"