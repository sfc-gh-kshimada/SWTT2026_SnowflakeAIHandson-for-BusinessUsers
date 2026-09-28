-- =============================================================================
-- 初めてのSnowflake AI 〜ビジネスユーザ編〜
-- 02_verify.sql : セットアップが正しく、実習が成立することを検証する
--
-- 実行者   : ACCOUNTADMIN
-- 前提     : 01_setup.sql が完了していること
-- 実行時間 : 約3分
--
-- 判定は各クエリの CHECK_RESULT 列を見る。
--   PASS  : 問題なし
--   FAIL  : 実習が成立しない。原因を解消して01_setup.sqlを再実行する
--   WAIT  : 時間経過で解決する。数分待って再確認する
--
-- [12][13] は AI_PARSE_DOCUMENT による報告書本文の文字起こし品質を見る。
-- 日本語は公式サポート言語一覧に含まれていないため、ここは
-- 一度PASSしたら安心してよい類のチェックではない。当日の朝も必ず回すこと。
-- =============================================================================

USE ROLE ACCOUNTADMIN;
USE WAREHOUSE COMPUTE_WH;
USE DATABASE SWT_CW_HANDSON;


-- -----------------------------------------------------------------------------
-- [1] 行数
--     12店舗 × 12商品 × 180日 = 25,920行
--     文書は主要12件 + ノイズ120件 = 132件
-- -----------------------------------------------------------------------------
SELECT
  '1. ROW COUNTS'                                                   AS check_name,
  (SELECT COUNT(*) FROM CORE.DIM_STORE)                             AS stores,
  (SELECT COUNT(*) FROM CORE.DIM_PRODUCT)                           AS products,
  (SELECT COUNT(*) FROM CORE.FACT_STORE_PRODUCT_DAY)                AS fact_rows,
  (SELECT COUNT(*) FROM DOCUMENTS.DOCUMENT_CORPUS)                  AS documents,
  CASE
    WHEN (SELECT COUNT(*) FROM CORE.DIM_STORE) = 12
     AND (SELECT COUNT(*) FROM CORE.DIM_PRODUCT) = 12
     AND (SELECT COUNT(*) FROM CORE.FACT_STORE_PRODUCT_DAY) = 25920
     AND (SELECT COUNT(*) FROM DOCUMENTS.DOCUMENT_CORPUS) = 132
      THEN 'PASS'
    ELSE 'FAIL : 期待値は 12 / 12 / 25920 / 132'
  END                                                               AS check_result;


-- -----------------------------------------------------------------------------
-- [2] 日付範囲
--     CURRENT_DATE基準で生成されているため、実施日がいつでも
--     「直近90日」がデータ範囲に収まる。
-- -----------------------------------------------------------------------------
SELECT
  '2. DATE RANGE'                                                   AS check_name,
  MIN(sales_date)                                                   AS data_start,
  MAX(sales_date)                                                   AS data_end,
  DATEDIFF(day, MIN(sales_date), MAX(sales_date)) + 1               AS day_count,
  DATEDIFF(day, MAX(sales_date), CURRENT_DATE())                    AS days_behind_today,
  CASE
    WHEN MAX(sales_date) = DATEADD(day, -1, CURRENT_DATE())
     AND DATEDIFF(day, MIN(sales_date), MAX(sales_date)) + 1 = 180
      THEN 'PASS'
    ELSE 'FAIL : 最終日は前日、期間は180日であるべき'
  END                                                               AS check_result
FROM CORE.FACT_STORE_PRODUCT_DAY;


-- -----------------------------------------------------------------------------
-- [3] 一意性と会計整合性
--     店舗商品日で一意。数量と金額の関係が崩れていないこと。
-- -----------------------------------------------------------------------------
SELECT
  '3a. UNIQUENESS'                                                  AS check_name,
  COUNT(*)                                                          AS duplicate_groups,
  CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL : 店舗商品日が重複している' END AS check_result
FROM (
  SELECT sales_date, store_id, product_id
  FROM CORE.FACT_STORE_PRODUCT_DAY
  GROUP BY sales_date, store_id, product_id
  HAVING COUNT(*) <> 1
);

SELECT
  '3b. ACCOUNTING'                                                  AS check_name,
  COUNT(*)                                                          AS invalid_rows,
  CASE WHEN COUNT(*) = 0 THEN 'PASS' ELSE 'FAIL : 数量または金額の整合性が崩れている' END AS check_result
FROM CORE.FACT_STORE_PRODUCT_DAY
WHERE demand_units   < 0
   OR sold_units     < 0
   OR returned_units < 0
   OR sold_units     > demand_units
   OR returned_units > sold_units
   OR stockout_minutes NOT BETWEEN 0 AND 1440
   OR net_sales_yen <> list_sales_yen - discount_yen - return_yen;


-- -----------------------------------------------------------------------------
-- [4] 4ケースの分離 ★最重要
--
--     ここが実習の成否を決める。期待値から外れると、
--     参加者が「主役ケースを見つけられない」または
--     「原因を切り分けられない」状態になる。
--
--     期待値（母数が十分なため誤差は小さい）
--     ケース              店舗 商品  達成率 充足率 返品率 値引率 粗利率 欠品
--     FOCAL_PROMO_SUPPLY  S017 P042   98%   76%   8.5%  12%   29%   あり
--     CMP_HEALTHY_PROMO   S008 P042  127%  100%   2.0%  10%   31%   なし
--     CMP_SUPPLY_ONLY     S031 P042   77%   79%   2.0%   3%   36%   あり
--     CMP_MARGIN_ONLY     S017 P057   91%  100%   2.0%  18%   17%   なし
--
--     教育上の意図
--       S017/P042 は達成率98%で「売上は問題なさそう」に見える。
--       しかし充足率が最低、返品率が最高、欠品が発生している。
--       売上だけを見ていると異常に気づけない、という体験を作る。
-- -----------------------------------------------------------------------------
WITH case_metrics AS (
  SELECT
    case_id,
    store_id,
    store_name,
    product_id,
    product_name,
    ROUND(DIV0NULL(SUM(net_sales_yen), SUM(target_net_sales_yen)) * 100, 1) AS attainment_pct,
    ROUND(DIV0NULL(SUM(sold_units), SUM(demand_units)) * 100, 1)            AS fill_pct,
    ROUND(DIV0NULL(SUM(returned_units), SUM(sold_units)) * 100, 1)          AS return_pct,
    ROUND(DIV0NULL(SUM(discount_yen), SUM(list_sales_yen)) * 100, 1)        AS discount_pct,
    ROUND(DIV0NULL(SUM(net_sales_yen - cogs_yen), SUM(net_sales_yen)) * 100, 1) AS margin_pct,
    ROUND(SUM(stockout_minutes) / 60, 1)                                    AS stockout_hours
  FROM CORE.FACT_STORE_PRODUCT_DAY
  WHERE case_id IS NOT NULL
  GROUP BY ALL
)
SELECT
  '4. CASE SEPARATION'                                              AS check_name,
  case_id,
  store_name,
  product_name,
  attainment_pct,
  fill_pct,
  return_pct,
  discount_pct,
  margin_pct,
  stockout_hours,
  CASE case_id
    WHEN 'FOCAL_PROMO_SUPPLY' THEN
      IFF(attainment_pct BETWEEN 92 AND 104
          AND fill_pct BETWEEN 70 AND 82
          AND return_pct BETWEEN 7.5 AND 9.5
          AND margin_pct BETWEEN 26 AND 32
          AND stockout_hours > 0, 'PASS', 'FAIL')
    WHEN 'CMP_HEALTHY_PROMO' THEN
      IFF(attainment_pct > 115
          AND fill_pct >= 99
          AND return_pct < 3.5
          AND stockout_hours = 0, 'PASS', 'FAIL')
    WHEN 'CMP_SUPPLY_ONLY' THEN
      IFF(attainment_pct BETWEEN 70 AND 84
          AND fill_pct BETWEEN 73 AND 85
          AND return_pct < 3.5
          AND stockout_hours > 0, 'PASS', 'FAIL')
    WHEN 'CMP_MARGIN_ONLY' THEN
      IFF(attainment_pct BETWEEN 85 AND 97
          AND fill_pct >= 99
          AND margin_pct BETWEEN 13 AND 21
          AND stockout_hours = 0, 'PASS', 'FAIL')
  END                                                               AS check_result
FROM case_metrics
ORDER BY case_id;


-- -----------------------------------------------------------------------------
-- [5] 主役ケースが売上以外の指標で発見できること
--     販促期間の全店舗商品のうち、返品率が最悪であることを確認する。
--     ここがPASSしないと、1問目で参加者がS017/P042に到達できない。
-- -----------------------------------------------------------------------------
WITH promo_window AS (
  SELECT f.*
  FROM CORE.FACT_STORE_PRODUCT_DAY f
  CROSS JOIN CORE.V_PARAMS p
  WHERE f.sales_date BETWEEN p.promo_start AND p.promo_end
),
ranked AS (
  SELECT
    store_id,
    product_id,
    DIV0NULL(SUM(returned_units), SUM(sold_units))                  AS return_rate,
    DIV0NULL(SUM(sold_units), SUM(demand_units))                    AS fill_rate,
    DIV0NULL(SUM(net_sales_yen - cogs_yen), SUM(net_sales_yen))     AS margin_rate,
    RANK() OVER (ORDER BY DIV0NULL(SUM(returned_units), SUM(sold_units)) DESC) AS return_rank,
    RANK() OVER (ORDER BY DIV0NULL(SUM(sold_units), SUM(demand_units)) ASC)    AS fill_rank,
    RANK() OVER (ORDER BY DIV0NULL(SUM(net_sales_yen - cogs_yen),
                                   SUM(net_sales_yen)) ASC)         AS margin_rank
  FROM promo_window
  GROUP BY store_id, product_id
)
SELECT
  '5. DISCOVERABILITY'                                              AS check_name,
  MAX(IFF(store_id = 'S017' AND product_id = 'P042', return_rank, NULL)) AS focal_return_rank,
  MAX(IFF(store_id = 'S017' AND product_id = 'P042', fill_rank,   NULL)) AS focal_fill_rank,
  MAX(IFF(store_id = 'S017' AND product_id = 'P057', margin_rank, NULL)) AS margin_case_margin_rank,
  CASE
    WHEN MAX(IFF(store_id = 'S017' AND product_id = 'P042', return_rank, NULL)) = 1
     AND MAX(IFF(store_id = 'S017' AND product_id = 'P042', fill_rank, NULL)) <= 3
     AND MAX(IFF(store_id = 'S017' AND product_id = 'P057', margin_rank, NULL)) = 1
      THEN 'PASS'
    ELSE 'FAIL : 主役ケースが指標のワースト上位に出ていない。実習1問目が成立しない'
  END                                                               AS check_result
FROM ranked;


-- -----------------------------------------------------------------------------
-- [6] Semantic View が実際にクエリできること
--     Agentは内部でこの形のSQLを生成する。
-- -----------------------------------------------------------------------------
SELECT *
FROM SEMANTIC_VIEW(
  SEMANTIC.RETAIL_PERFORMANCE
  DIMENSIONS performance.store_name, performance.product_name
  METRICS
    performance.sales_plan_attainment_rate,
    performance.demand_fill_rate,
    performance.return_rate,
    performance.gross_margin_rate,
    performance.total_stockout_hours
  WHERE performance.sales_date >= DATEADD(day, -90, CURRENT_DATE())
    AND (
      (performance.store_id = 'S017' AND performance.product_id IN ('P042', 'P057'))
      OR (performance.store_id IN ('S008', 'S031') AND performance.product_id = 'P042')
    )
)
ORDER BY store_name, product_name;


-- -----------------------------------------------------------------------------
-- [7] Cortex Search Service の準備状態
--     INDEXING_STATE / SERVING_STATE の値は RUNNING または SUSPENDED。
--     ACTIVE という値は存在しないので注意。
--     SOURCE_DATA_NUM_ROWS が132件になっていれば取り込みが完了している。
-- -----------------------------------------------------------------------------
SELECT
  '7. SEARCH STATE'                                                 AS check_name,
  SERVICE_NAME                                                      AS service_name,
  INDEXING_STATE                                                    AS indexing_state,
  SERVING_STATE                                                     AS serving_state,
  SOURCE_DATA_NUM_ROWS                                              AS indexed_rows,
  DATA_TIMESTAMP                                                    AS data_timestamp,
  INDEXING_ERROR                                                    AS indexing_error,
  CASE
    WHEN INDEXING_ERROR IS NOT NULL
      THEN 'FAIL : indexing_errorを確認する'
    WHEN SOURCE_DATA_NUM_ROWS = 132 AND DATA_TIMESTAMP IS NOT NULL
      THEN 'PASS'
    ELSE 'WAIT : 取り込み中。数分待って再実行する'
  END                                                               AS check_result
FROM SWT_CW_HANDSON.INFORMATION_SCHEMA.CORTEX_SEARCH_SERVICES
WHERE SERVICE_NAME = 'ENTERPRISE_DOCUMENT_SEARCH';


-- -----------------------------------------------------------------------------
-- [8] 主要文書が存在すること
--     DOC-F001〜F008、DOC-C001〜C002、DOC-P001〜P002 の12件。
--     1件でも欠けると2問目の反証が成立しない。
-- -----------------------------------------------------------------------------
SELECT
  '8. CURATED DOCS'                                                 AS check_name,
  COUNT(*)                                                          AS curated_count,
  COUNT_IF(document_id LIKE 'DOC-F%')                               AS focal_docs,
  COUNT_IF(document_id LIKE 'DOC-C%')                               AS compare_docs,
  COUNT_IF(document_id LIKE 'DOC-P%')                               AS policy_docs,
  CASE
    WHEN COUNT(*) = 12
     AND COUNT_IF(document_id LIKE 'DOC-F%') = 8
     AND COUNT_IF(document_id LIKE 'DOC-C%') = 2
     AND COUNT_IF(document_id LIKE 'DOC-P%') = 2
      THEN 'PASS'
    ELSE 'FAIL : 期待値は 12 / 8 / 2 / 2'
  END                                                               AS check_result
FROM DOCUMENTS.DOCUMENT_CORPUS
WHERE document_id NOT LIKE 'DOC-G%';


-- -----------------------------------------------------------------------------
-- [9] Search が期待文書を返すこと
--     2問目で参加者が必要とする文書が、実際に検索でヒットするかを確認する。
--     期待文書がヒットしないと、採点チェックリストを満たせない。
-- -----------------------------------------------------------------------------
WITH probes AS (
  SELECT '9a. 欠品' AS probe_name, 'DOC-F001' AS expected_doc,
         SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
           'SWT_CW_HANDSON.DOCUMENTS.ENTERPRISE_DOCUMENT_SEARCH',
           '{"query": "夕方に商品が欠品して販売を再開できなかった",
             "columns": ["DOCUMENT_ID", "TITLE"],
             "filter": {"@eq": {"STORE_ID": "S017"}},
             "limit": 5}'
         ) AS raw
  UNION ALL
  SELECT '9b. 反証（人手不足）', 'DOC-F007',
         SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
           'SWT_CW_HANDSON.DOCUMENTS.ENTERPRISE_DOCUMENT_SEARCH',
           '{"query": "シフト充足率は計画どおりで人手不足は欠品の主因ではない",
             "columns": ["DOCUMENT_ID", "TITLE"],
             "limit": 5}'
         )
  UNION ALL
  SELECT '9c. 外装不良', 'DOC-F003',
         SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
           'SWT_CW_HANDSON.DOCUMENTS.ENTERPRISE_DOCUMENT_SEARCH',
           '{"query": "外装箱のつぶれが確認されたが商品本体の品質に影響はない",
             "columns": ["DOCUMENT_ID", "TITLE"],
             "limit": 5}'
         )
  UNION ALL
  SELECT '9d. 業務ポリシー', 'DOC-P001',
         SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
           'SWT_CW_HANDSON.DOCUMENTS.ENTERPRISE_DOCUMENT_SEARCH',
           '{"query": "販促で需要が増える場合の追加発注と店舗連絡のルール",
             "columns": ["DOCUMENT_ID", "TITLE"],
             "limit": 5}'
         )
  UNION ALL
  SELECT '9e. 比較店舗', 'DOC-F006',
         SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
           'SWT_CW_HANDSON.DOCUMENTS.ENTERPRISE_DOCUMENT_SEARCH',
           '{"query": "事前に増便して欠品を回避し不良品を分離した事例",
             "columns": ["DOCUMENT_ID", "TITLE"],
             "limit": 5}'
         )
),
hits AS (
  SELECT
    p.probe_name,
    p.expected_doc,
    ARRAY_AGG(f.value:DOCUMENT_ID::VARCHAR) WITHIN GROUP (ORDER BY f.index) AS returned_docs
  FROM probes p,
       LATERAL FLATTEN(input => PARSE_JSON(p.raw):results) f
  GROUP BY p.probe_name, p.expected_doc
)
SELECT
  '9. SEARCH RELEVANCE'                                             AS check_name,
  probe_name,
  expected_doc,
  returned_docs,
  CASE
    WHEN ARRAY_CONTAINS(expected_doc::VARIANT, returned_docs) THEN 'PASS'
    ELSE 'FAIL : 期待文書が上位5件に出ていない。2問目の採点項目を満たせない'
  END                                                               AS check_result
FROM hits
ORDER BY probe_name;


-- -----------------------------------------------------------------------------
-- [10] Agent 3体が存在すること
--
--   3体は定義が同一で sample_questions だけが違う。
--     _1 実習1と2      4問
--     _2 実習3から5    3問（すべて添付前提）
--     _3 付録         14問
--   3体に分けている理由は、CoWorkの候補質問を実習の段階ごとに絞ることで
--   40名の進行を揃えられるようにするため。
-- -----------------------------------------------------------------------------
SHOW AGENTS LIKE 'BUSINESS_DECISION_AGENT_%' IN SCHEMA AI;

SELECT
  '10. AGENT'                                                       AS check_name,
  COUNT(*)                                                          AS agent_count,
  CASE WHEN COUNT(*) = 3 THEN 'PASS'
       ELSE 'FAIL : Agentが3体そろっていない' END                   AS check_result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


-- -----------------------------------------------------------------------------
-- [10b] Web検索が使える状態か
--
--   ENABLE_CORTEX_WEBSEARCH は既定 false。
--   false のままでも Agent3 の CREATE は成功し、
--   参加者がWeb検索の質問を投げた瞬間に初めて失敗する。
--   静かに通る類の不具合なので必ず値を見る。
-- -----------------------------------------------------------------------------
SHOW PARAMETERS LIKE 'ENABLE_CORTEX_WEBSEARCH' IN ACCOUNT;

SELECT
  '10b. WEBSEARCH PARAM'                                            AS check_name,
  "value"                                                           AS param_value,
  CASE WHEN LOWER("value") = 'true' THEN 'PASS'
       ELSE 'FAIL : ALTER ACCOUNT SET ENABLE_CORTEX_WEBSEARCH = TRUE を実行する'
  END                                                               AS check_result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


-- -----------------------------------------------------------------------------
-- [10c] web_search を持つのが Agent3 だけか
--
--   実習1・2（Agent1）と実習3から5（Agent2）で外部通信が起きてはいけない。
--   再現性が落ちるうえ、参加者の質問内容がSnowflakeの外に出る。
--   付録のAgent3だけに限定されていることを確認する。
--
--   SYSTEM$GET_AGENT_SPECIFICATION のような関数は存在しない。
--   DESCRIBE AGENT の agent_spec 列を RESULT_SCAN で受けるしかないため、
--   3体を1クエリにまとめられず3組の実行になる。
-- -----------------------------------------------------------------------------
DESCRIBE AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_1;
SELECT
  '10c. WEB_SEARCH SCOPE'                          AS check_name,
  'BUSINESS_DECISION_AGENT_1'                      AS agent_name,
  CONTAINS("agent_spec", 'web_search')             AS has_web_search,
  CASE WHEN NOT CONTAINS("agent_spec", 'web_search') THEN 'PASS'
       ELSE 'FAIL : 実習1・2用のAgentにweb_searchが混入している' END AS check_result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

DESCRIBE AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_2;
SELECT
  '10c. WEB_SEARCH SCOPE'                          AS check_name,
  'BUSINESS_DECISION_AGENT_2'                      AS agent_name,
  CONTAINS("agent_spec", 'web_search')             AS has_web_search,
  CASE WHEN NOT CONTAINS("agent_spec", 'web_search') THEN 'PASS'
       ELSE 'FAIL : 実習3から5用のAgentにweb_searchが混入している' END AS check_result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

DESCRIBE AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_3;
SELECT
  '10c. WEB_SEARCH SCOPE'                          AS check_name,
  'BUSINESS_DECISION_AGENT_3'                      AS agent_name,
  CONTAINS("agent_spec", 'web_search')             AS has_web_search,
  CASE WHEN CONTAINS("agent_spec", 'web_search') THEN 'PASS'
       ELSE 'FAIL : 付録Agentにweb_searchが入っていない' END AS check_result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


-- =============================================================================
-- [11] CoWork UI での動作確認（手作業。SQLでは代替できない）
--
--   準備
--     Snowsight左メニュー > Snowflake CoWork > Agent選択で
--     「クレストリヴェルタ 経営判断アシスタント」を選ぶ。
--
--   実習1問目
--     直近90日について、店舗と商品の組み合わせごとに計画達成率、需要充足率、
--     返品率、粗利率、欠品時間を比較し、優先して確認すべき対象を3件挙げてください
--
--     合格条件（3件のうち2件以上が以下に該当すること）
--       [ ] 横浜みなと店 × クレストリフレッシュウォーター
--       [ ] 名古屋ささしま店 × クレストリフレッシュウォーター
--       [ ] 横浜みなと店 × リヴェルタ冷凍パスタ
--     応答時間 : 2分以内
--
--   実習2問目
--     横浜みなと店のクレストリフレッシュウォーターについて、
--     数値と現場文書を横断して原因候補を調べ、反証も示してください
--
--     採点チェックリスト（5項目中4項目以上でPASS）
--       [ ] 需要増と供給不足を区別している
--       [ ] 外装不良を返品増の別要因として挙げている
--       [ ] 値引きが粗利を押し下げたと指摘している
--       [ ] 人手不足または価格を反証として除外している
--       [ ] 東京ベイ店との差を対策の根拠にしている
--     加点
--       [ ] 文書タイトルを引用している
--       [ ] 事実と仮説を分けて書いている
--     応答時間 : 2分以内
--
--   追加課題（時間が余った場合のみ）
--     my_area_business_plan_a.xlsx をアップロードして
--     「アップロードした来月の事業計画を、企業データと現場文書に照らして評価してください」
--
--     合格条件
--       [ ] 前回の販促前倒しの失敗に触れている
--       [ ] 業務ポリシーの5営業日前連絡ルールに触れている
--       [ ] 企業データ由来とMy Data由来を区別している
--
--
-- =============================================================================


-- -----------------------------------------------------------------------------
-- [12] 報告書本文の文字起こし品質 ★最重要
--
--   報告書本文は AI_PARSE_DOCUMENT でPDFから文字起こししている。
--   日本語は公式サポート言語一覧に含まれていないため、
--   モデル更新やPDF再生成で品質が落ちる可能性を常に抱えている。
--   落ちたことを当日の朝に気づける状態を作るのがこのブロックの役割。
--
--   3段階で見る。
--     件数     : 4件そろっているか（PDFが1本でも読めなければ欠ける）
--     本文長   : 極端に短くないか。実測は790〜845文字。下限を600に置く
--     キー語句 : 実習が成立するために本文に必ず存在しなければならない語句
--
--   キー語句の選定理由
--     RPT-S017-P042 は主役。「計画比98パーセントで着地」と「影響は軽微」の
--     両方が読めなければ、実習1の「報告は正しいが不都合を書いていない」
--     という反証体験が成立しない。ここが最重要。
--     他3件は対比材料なので、それぞれの論点を示す語で足りる。
--
--   NG時の退避手順は 01_setup.sql セクション7末尾に書いてある。
-- -----------------------------------------------------------------------------
WITH expected AS (
  SELECT * FROM (VALUES
    ('RPT-S017-P042', '計画比98パーセントで着地', '影響は軽微'),
    ('RPT-S008-P042', '欠品',                     '1.4倍'),
    ('RPT-S031-P042', '納品数量',                 '77パーセント'),
    ('RPT-S017-P057', '在庫',                     '値引き')
  ) AS e(report_id, key1, key2)
),
checked AS (
  SELECT
    e.report_id,
    r.source_file,
    LENGTH(r.body)                               AS body_len,
    CONTAINS(r.body, e.key1)                     AS has_key1,
    CONTAINS(r.body, e.key2)                     AS has_key2,
    -- メタデータの報告文言が本文に実在するか。
    -- SQL側の属性とPDF側の本文がずれていないことの強い証拠になる。
    CONTAINS(r.body, r.reported_attainment_text) AS attainment_consistent
  FROM expected e
  LEFT JOIN SWT_CW_HANDSON.DOCUMENTS.MANAGER_REPORT r
         ON r.report_id = e.report_id
)
SELECT
  '[12] 文字起こし品質' AS check_name,
  report_id,
  source_file,
  body_len,
  has_key1,
  has_key2,
  attainment_consistent,
  CASE
    WHEN source_file IS NULL             THEN 'FAIL: 行が存在しない（PDF解析に失敗）'
    WHEN body_len IS NULL OR body_len = 0 THEN 'FAIL: 本文が空'
    WHEN body_len < 600                   THEN 'FAIL: 本文が短すぎる（解析品質の劣化）'
    WHEN NOT has_key1 OR NOT has_key2     THEN 'FAIL: キー語句が読めていない'
    WHEN NOT attainment_consistent        THEN 'FAIL: メタデータと本文が不整合'
    ELSE 'PASS'
  END AS check_result
FROM checked
ORDER BY report_id;


-- -----------------------------------------------------------------------------
-- [13] 文字起こしの総合判定
--
--   [12] の表を目視するのを忘れても、この1行だけ見れば足りるようにする。
-- -----------------------------------------------------------------------------
WITH expected AS (
  SELECT * FROM (VALUES
    ('RPT-S017-P042', '計画比98パーセントで着地', '影響は軽微'),
    ('RPT-S008-P042', '欠品',                     '1.4倍'),
    ('RPT-S031-P042', '納品数量',                 '77パーセント'),
    ('RPT-S017-P057', '在庫',                     '値引き')
  ) AS e(report_id, key1, key2)
)
SELECT
  '[13] 文字起こし総合判定' AS check_name,
  COUNT(*)                                        AS expected_rows,
  COUNT(r.report_id)                              AS actual_rows,
  MIN(LENGTH(r.body))                             AS min_body_len,
  COUNT_IF(CONTAINS(r.body, e.key1)
       AND CONTAINS(r.body, e.key2))              AS key_ok_rows,
  CASE WHEN COUNT(r.report_id) = 4
        AND MIN(LENGTH(r.body)) >= 600
        AND COUNT_IF(CONTAINS(r.body, e.key1)
                 AND CONTAINS(r.body, e.key2)) = 4
       THEN 'PASS'
       ELSE 'FAIL: 実施しない。01_setup.sql セクション7の退避手順に切り替える'
  END                                             AS check_result
FROM expected e
LEFT JOIN SWT_CW_HANDSON.DOCUMENTS.MANAGER_REPORT r
       ON r.report_id = e.report_id;


-- -----------------------------------------------------------------------------
-- [14] 内部ステージにPDFが4本あるか
--
--   out/pdf/ の月次業績報告4本がアップロードされていること。
--   判定は [12][13] を優先する。本文が取れていれば実習は成立する。
-- -----------------------------------------------------------------------------
ALTER STAGE SWT_CW_HANDSON.DOCUMENTS.STG_SOURCE_PDF REFRESH;

SELECT
  '[14] 内部ステージ' AS check_name,
  RELATIVE_PATH,
  SIZE,
  LAST_MODIFIED
FROM DIRECTORY(@SWT_CW_HANDSON.DOCUMENTS.STG_SOURCE_PDF)
ORDER BY RELATIVE_PATH;


-- -----------------------------------------------------------------------------
-- [15] 新ソースの件数と、報告書Searchが本文を拾えているか
--
--   テーブルが正しくてもSearchのインデックスが古いと実習1が滑る。
--   TARGET_LAG = '1 day' なので、PDFを差し替えた直後は
--   インデックスが追いついていない可能性がある。
--   主役の報告書が検索でヒットすることを直接確かめる。
-- -----------------------------------------------------------------------------
SELECT
  '[15] 新ソース件数' AS check_name,
  (SELECT COUNT(*) FROM SWT_CW_HANDSON.DOCUMENTS.MANAGER_REPORT)  AS manager_reports,
  (SELECT COUNT(*) FROM SWT_CW_HANDSON.DOCUMENTS.CUSTOMER_REVIEW) AS customer_reviews,
  CASE WHEN (SELECT COUNT(*) FROM SWT_CW_HANDSON.DOCUMENTS.MANAGER_REPORT) = 4
        AND (SELECT COUNT(*) FROM SWT_CW_HANDSON.DOCUMENTS.CUSTOMER_REVIEW) > 500
       THEN 'PASS' ELSE 'FAIL' END AS check_result;

SELECT PARSE_JSON(
  SNOWFLAKE.CORTEX.SEARCH_PREVIEW(
    'SWT_CW_HANDSON.DOCUMENTS.MANAGER_REPORT_SEARCH',
    '{"query": "入荷数量が想定を下回った店舗の報告", "columns": ["report_id","store_id","source_file"], "limit": 4}'
  )
):results AS search_results;


-- =============================================================================
-- [17] ガバナンス付録: オブジェクトが揃っているか
-- =============================================================================
WITH want AS (
  SELECT * FROM VALUES
    ('TABLE',         'ROLE_REGION_MAP'),
    ('TABLE',         'CUSTOMER_CONTACT'),
    ('SEMANTIC VIEW', 'CUSTOMER_GOVERNANCE')
  AS v(kind, name)
),
got AS (
  SELECT 'TABLE' AS kind, table_name AS name
  FROM SWT_CW_HANDSON.INFORMATION_SCHEMA.TABLES
  WHERE table_schema = 'GOVERNED' AND table_type = 'BASE TABLE'
  UNION ALL
  -- INFORMATION_SCHEMA.SEMANTIC_VIEWS の列名は SCHEMA / NAME。
  -- TABLES のような SEMANTIC_VIEW_SCHEMA ではない。予約語なので引用符で囲む。
  SELECT 'SEMANTIC VIEW', 'CUSTOMER_GOVERNANCE'
  FROM SWT_CW_HANDSON.INFORMATION_SCHEMA.SEMANTIC_VIEWS
  WHERE "SCHEMA" = 'GOVERNED'
    AND "NAME" = 'CUSTOMER_GOVERNANCE'
)
SELECT '[17] GOVERNEDオブジェクト' AS check_name,
       w.kind, w.name,
       IFF(g.name IS NOT NULL, 'PASS', 'FAIL 存在しない') AS result
FROM want w
LEFT JOIN got g ON g.kind = w.kind AND g.name = w.name
ORDER BY w.kind, w.name;


-- =============================================================================
-- [18] ガバナンス付録: ポリシーが付与されているか
--
--   POLICY_REFERENCES で実際の付与状況を見る。
--   ポリシーを CREATE しただけでは効かない。ALTER TABLE での付与が必要。
--   CREATE OR REPLACE TABLE は付与を落とすため、ここが FAIL になったときは
--   01_setup.sql の 12.7.3 が流れていない可能性を疑う。
-- =============================================================================
WITH refs AS (
  SELECT policy_kind, policy_name, ref_column_name
  FROM TABLE(SWT_CW_HANDSON.INFORMATION_SCHEMA.POLICY_REFERENCES(
    REF_ENTITY_NAME => 'SWT_CW_HANDSON.GOVERNED.CUSTOMER_CONTACT',
    REF_ENTITY_DOMAIN => 'TABLE'
  ))
)
SELECT '[18] ポリシー付与' AS check_name,
       (SELECT COUNT(*) FROM refs WHERE policy_kind = 'MASKING_POLICY')    AS masking_count,
       (SELECT COUNT(*) FROM refs WHERE policy_kind = 'ROW_ACCESS_POLICY') AS row_access_count,
       (SELECT LISTAGG(ref_column_name, ',') WITHIN GROUP (ORDER BY ref_column_name)
        FROM refs WHERE policy_kind = 'MASKING_POLICY')                    AS masked_columns,
       IFF((SELECT COUNT(*) FROM refs WHERE policy_kind = 'MASKING_POLICY') = 4
           AND (SELECT COUNT(*) FROM refs WHERE policy_kind = 'ROW_ACCESS_POLICY') = 1,
           'PASS', 'FAIL マスキング4本と行アクセス1本が必要') AS result;


-- =============================================================================
-- [19] ガバナンス付録: マスキングが効いているか
--
--   制限されているのが正常。逆になっていたらポリシーが効いていない。
--   このスクリプトは ACCOUNTADMIN で実行する前提。
--   SWT_DATA_STEWARD で実行すると意図的に FAIL する。
-- =============================================================================
SELECT '[19] マスキング' AS check_name,
       CURRENT_ROLE() AS run_role,
       COUNT_IF(email LIKE '%***@%')        AS email_masked,
       COUNT_IF(phone LIKE '%****-%')       AS phone_masked,
       COUNT_IF(customer_name LIKE '%＊＊') AS name_masked,
       COUNT_IF(MONTH(birth_date) = 1 AND DAY(birth_date) = 1) AS dob_masked,
       COUNT(*) AS rows_seen,
       IFF(COUNT(*) > 0
           AND COUNT_IF(email LIKE '%***@%') = COUNT(*)
           AND COUNT_IF(phone LIKE '%****-%') = COUNT(*)
           AND COUNT_IF(customer_name LIKE '%＊＊') = COUNT(*)
           AND COUNT_IF(MONTH(birth_date) = 1 AND DAY(birth_date) = 1) = COUNT(*),
           'PASS', 'FAIL 全行がマスクされていない') AS result
FROM SWT_CW_HANDSON.GOVERNED.CUSTOMER_CONTACT;


-- =============================================================================
-- [20] ガバナンス付録: 行アクセスポリシーが効いているか
--
--   ACCOUNTADMIN には関東だけを許可している。全件見えていたら FAIL。
-- =============================================================================
SELECT '[20] 行アクセス' AS check_name,
       COUNT(*) AS visible_rows,
       COUNT(DISTINCT region_name) AS visible_regions,
       LISTAGG(DISTINCT region_name, ',') AS region_list,
       IFF(COUNT(*) > 0 AND COUNT(*) < 300 AND COUNT(DISTINCT region_name) = 1,
           'PASS', 'FAIL 1エリアに絞られていない') AS result
FROM SWT_CW_HANDSON.GOVERNED.CUSTOMER_CONTACT;


-- =============================================================================
-- [21] ガバナンス付録: PIIをCortex Searchに載せていないか ★安全側の検査
--
--   Cortex Search Service は作成時にインデックスを実体化するため、
--   呼び出し元のマスキングポリシーが適用されない。
--   GOVERNED スキーマに Search Service を作るとマスクを迂回して素の値が返る。
--   0件であることが正常。
-- =============================================================================
SHOW CORTEX SEARCH SERVICES IN SCHEMA SWT_CW_HANDSON.GOVERNED;

SELECT '[21] PIIをSearchに載せていない' AS check_name,
       COUNT(*) AS search_services,
       IFF(COUNT(*) = 0, 'PASS',
           'FAIL GOVERNEDにSearchサービスがある。マスクを迂回する恐れ') AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


-- =============================================================================
-- [22] ガバナンス付録: ツールがAgent3だけに付いているか
--
--   実習1〜5で使うAgent1・Agent2 がPIIに触れないことを担保する。
-- =============================================================================
DESCRIBE AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_1;
SELECT '[22a] Agent1 ガバナンスツールなし' AS check_name,
       IFF(CONTAINS("agent_spec", 'governed_customer_analytics'),
           'FAIL 実習用Agentに付いている', 'PASS') AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

DESCRIBE AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_2;
SELECT '[22b] Agent2 ガバナンスツールなし' AS check_name,
       IFF(CONTAINS("agent_spec", 'governed_customer_analytics'),
           'FAIL 実習用Agentに付いている', 'PASS') AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

DESCRIBE AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_3;
SELECT '[22c] Agent3 ガバナンスツールあり' AS check_name,
       IFF(CONTAINS("agent_spec", 'governed_customer_analytics'),
           'PASS', 'FAIL 付録Agentに付いていない') AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


-- =============================================================================
-- [25] 参加者ロールの権限
--
--   CoWork で Agent を使うために必要な権限が揃っているかを見る。
--   SNOWFLAKE INTELLIGENCE への USAGE が抜けるとAgent一覧が空になり、
--   実習が1問も始まらない。ここは特に重要。
--
--   Semantic View の権限は SELECT。USAGE ではない。
--   ドキュメントは USAGE と書いているが実装は SELECT（実測 2026-09-08）。
-- =============================================================================
SHOW GRANTS TO ROLE SWT_PARTICIPANT;
SELECT '[25] 参加者ロールの権限' AS check_name,
       -- SHOW GRANTS の granted_on は 'AGENT' ではなく 'CORTEX_AGENT'（実測 2026-09-08）
       COUNT_IF("granted_on" = 'CORTEX_AGENT'           AND "privilege" = 'USAGE')  AS agents,
       COUNT_IF("granted_on" = 'CORTEX_SEARCH_SERVICE'  AND "privilege" = 'USAGE')  AS searches,
       COUNT_IF("granted_on" = 'SEMANTIC_VIEW'          AND "privilege" = 'SELECT') AS semantic_views,
       COUNT_IF("granted_on" = 'SNOWFLAKE_INTELLIGENCE' AND "privilege" = 'USAGE')  AS cowork_object,
       COUNT_IF("granted_on" = 'WAREHOUSE'              AND "privilege" = 'USAGE')  AS warehouses,
       COUNT_IF("granted_on" = 'TABLE'                  AND "privilege" = 'SELECT') AS tables,
       IFF(COUNT_IF("granted_on" = 'CORTEX_AGENT' AND "privilege" = 'USAGE') = 3
           AND COUNT_IF("granted_on" = 'CORTEX_SEARCH_SERVICE' AND "privilege" = 'USAGE') = 3
           AND COUNT_IF("granted_on" = 'SEMANTIC_VIEW' AND "privilege" = 'SELECT') = 2
           AND COUNT_IF("granted_on" = 'SNOWFLAKE_INTELLIGENCE' AND "privilege" = 'USAGE') = 1
           AND COUNT_IF("granted_on" = 'WAREHOUSE' AND "privilege" = 'USAGE') >= 1
           AND COUNT_IF("granted_on" = 'TABLE' AND "privilege" = 'SELECT') >= 8,
           'PASS', 'FAIL 権限が不足している') AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


-- =============================================================================
-- [26] 行アクセスポリシーの参照表に参加者ロールが入っているか ★重要
--
--   これが抜けると参加者には顧客連絡先が1行も返らず、付録Fが成立しない。
--   参加者は SWT_PARTICIPANT で動くため、ACCOUNTADMIN だけでは足りない。
-- =============================================================================
SELECT '[26] RAP参照表' AS check_name,
       COUNT(*) AS rows_total,
       COUNT_IF(role_name = 'SWT_PARTICIPANT')  AS participant_row,
       COUNT_IF(role_name = 'ACCOUNTADMIN')     AS admin_row,
       COUNT_IF(role_name = 'SWT_DATA_STEWARD') AS steward_row,
       IFF(COUNT_IF(role_name = 'SWT_PARTICIPANT' AND region_name = '関東') = 1
           AND COUNT_IF(role_name = 'ACCOUNTADMIN' AND region_name = '関東') = 1
           AND COUNT_IF(role_name = 'SWT_DATA_STEWARD' AND region_name = '*') = 1,
           'PASS', 'FAIL 参加者ロールの行がないと付録Fが0件になる') AS result
FROM SWT_CW_HANDSON.GOVERNED.ROLE_REGION_MAP;


-- =============================================================================
-- [16] Go / No-Go 判定
--
--   すべて満たしたときのみ本番実施可とする。
--     [ ] [1]〜[10] のSQLチェックがすべてPASS（[7]はACTIVE）
--     [ ] [9a][9b][9c] で期待文書がヒットしている
--     [ ] [12] の4件すべてPASS、[13] がPASS ★最重要
--     [ ] [14] で報告書PDFが4本見えている
--     [ ] [15] の件数がPASSかつ主役の報告書が検索でヒットする
--     [ ] [17]〜[22] がすべてPASS（ガバナンス付録）
--     [ ] [25][26] がPASS（参加者ロールの権限）
--     [ ] ai.snowflake.com でロールを SWT_PARTICIPANT に切り替え、Agent 3体が見える
--     [ ] 実習1問目の合格条件を満たす
--     [ ] 実習2問目の採点チェックリストが4項目以上
--     [ ] 両問の応答時間が各2分以内
--     [ ] 3アカウント以上で同じ結果を再現できた
--     [ ] 障害時に切り替える模範出力を用意済み
--
--   1つでも欠ける場合は No-Go とし、原因を解消してから再判定する。
-- =============================================================================
