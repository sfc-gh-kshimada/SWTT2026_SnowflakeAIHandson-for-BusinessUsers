-- =============================================================================
-- 初めてのSnowflake AI 〜ビジネスユーザ編〜 （社内版） アカウント事前検査
--
--   各自のデモ/Trialアカウントで 01_setup.sql を流す前に実行し、
--   前提機能が使えることを確かめる。
--
--   実行順
--     sql/00_preflight.sql   このファイル
--     sql/01_setup.sql
--     sql/02_verify.sql
--     sql/04_teardown.sql    使い終わったら
-- =============================================================================
USE ROLE ACCOUNTADMIN;


-- =============================================================================
-- [1] リージョン
--
--   Cortex Search Service の作成時間がリージョンで桁違いに変わる。
--   実測: AWS 東京で 6〜8秒、他リージョンで約15分。
--   20アカウント × Search 3本なので、ここを外すと数時間の差になる。
-- =============================================================================
SELECT '[1] リージョン' AS check_name,
       CURRENT_REGION() AS region_raw,
       -- CURRENT_REGION() は PUBLIC.AWS_AP_NORTHEAST_1 の形で返る。
       -- リージョングループ名のプレフィックスが付くため、
       -- そのまま比較すると常に不一致になる（実測 2026-09-08）。
       SPLIT_PART(CURRENT_REGION(), '.', -1) AS region,
       IFF(SPLIT_PART(CURRENT_REGION(), '.', -1) = 'AWS_AP_NORTHEAST_1', 'PASS',
           'WARN 東京以外。Cortex Searchの作成に15分かかる可能性がある') AS result;


-- =============================================================================
-- [2] エディション（機能プローブで確かめる）
--
--   ダイナミックデータマスキングと行アクセスポリシーは Enterprise 以上。
--   Standard だと 01_setup.sql の 12.7（付録F）が失敗する。
--
--   CURRENT_ACCOUNT_EDITION() と SYSTEM$GET_ACCOUNT_EDITION() は
--   どちらも存在しない（Unknown function。実測 2026-09-08）。
--   そのためエディション名を直接取るのではなく、
--   実際にマスキングポリシーを作って消すことで能力を確かめる。
--   これが通れば付録Fは必ず動くと言える。
-- =============================================================================
-- CREATE SCHEMA は親データベースを自動作成しない。先にデータベースを作る。
CREATE DATABASE IF NOT EXISTS SWT_CW_HANDSON_PREFLIGHT
  COMMENT = '事前検査用の使い捨て。このスクリプトの最後で削除する';
CREATE SCHEMA IF NOT EXISTS SWT_CW_HANDSON_PREFLIGHT.PROBE;

EXECUTE IMMEDIATE $$
BEGIN
  CREATE OR REPLACE MASKING POLICY SWT_CW_HANDSON_PREFLIGHT.PROBE.EDITION_PROBE
    AS (val STRING) RETURNS STRING -> '***';
  DROP MASKING POLICY SWT_CW_HANDSON_PREFLIGHT.PROBE.EDITION_PROBE;
  RETURN 'PASS マスキングポリシーを作成できた。Enterprise以上';
EXCEPTION
  WHEN OTHER THEN
    RETURN 'FAIL マスキングポリシーを作成できない。Standardの可能性が高い: '
           || SQLERRM;
END;
$$;

DROP SCHEMA IF EXISTS SWT_CW_HANDSON_PREFLIGHT.PROBE;
DROP DATABASE IF EXISTS SWT_CW_HANDSON_PREFLIGHT;


-- =============================================================================
-- [3] ウェアハウス
--
--   01_setup.sql と Agent の tool_resources が COMPUTE_WH を前提にしている。
--   無ければ作る（XSMALL・60秒で自動停止）。
-- =============================================================================
CREATE WAREHOUSE IF NOT EXISTS COMPUTE_WH
  WAREHOUSE_SIZE = XSMALL AUTO_SUSPEND = 60 AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;
SHOW WAREHOUSES LIKE 'COMPUTE_WH';
SELECT '[3] ウェアハウス' AS check_name,
       COUNT(*) AS found,
       IFF(COUNT(*) = 1, 'PASS', 'FAIL COMPUTE_WH が存在しない') AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));

-- クレジットの無駄を削る。既定の AUTO_SUSPEND は600秒。
ALTER WAREHOUSE COMPUTE_WH SET
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  STATEMENT_TIMEOUT_IN_SECONDS = 600;


-- =============================================================================
-- [4] タイムゾーン
--
--   V_PARAMS は CURRENT_DATE 基準でデータを生成する。
--   アカウント既定は America/Los_Angeles のため、セットアップ時刻と
--   参加者の質問時刻で日付がずれ、「直近90日」の窓が変わることがある。
-- =============================================================================
-- 共有デモアカウントではアカウント全体の設定を変えないよう、セッションに留める。
ALTER SESSION SET TIMEZONE = 'Asia/Tokyo';

SELECT '[4] タイムゾーン' AS check_name,
       CURRENT_TIMESTAMP() AS now_local,
       'セッションを Asia/Tokyo に設定した' AS result;


-- =============================================================================
-- [5] 共有アカウントでないことの確認
--
--   01_setup.sql は ENABLE_CORTEX_WEBSEARCH（アカウントパラメータ）を TRUE にし、
--   SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT に Agent を3体追加する。
--   他の人も使うデモアカウントでは、その人たちの CoWork にも Agent が見える。
--   ユーザーが自分以外にいる場合は WARN を出す。止めはしない。
-- =============================================================================
SHOW USERS;
SELECT '[5] 共有アカウント判定' AS check_name,
       COUNT_IF("disabled" = 'false'
                AND COALESCE("type", 'PERSON') NOT IN ('SERVICE', 'LEGACY_SERVICE'))
         AS active_person_users,
       IFF(active_person_users <= 1,
           'PASS 自分専用',
           'WARN 他のユーザーがいる。Web検索の有効化とCoWorkへのAgent追加が他者にも見えることを了承のうえ進める')
         AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


-- =============================================================================
-- [6] Cortex のリージョン間推論
--
--   東京では Analyst / Search がネイティブ提供されるため通常は不要。
--   東京以外のアカウントを使う場合は有効化しないとモデルが使えない。
-- =============================================================================
SHOW PARAMETERS LIKE 'CORTEX_ENABLED_CROSS_REGION' IN ACCOUNT;
SELECT '[6] クロスリージョン推論' AS check_name,
       "value" AS current_value,
       IFF(SPLIT_PART(CURRENT_REGION(), '.', -1) = 'AWS_AP_NORTHEAST_1',
           'PASS 東京なので設定不要',
           IFF(UPPER("value") = 'ANY_REGION', 'PASS',
               'WARN 東京以外なので ANY_REGION の設定を検討する')) AS result
FROM TABLE(RESULT_SCAN(LAST_QUERY_ID()));


-- =============================================================================
-- [7] クレジットのガード（任意）
--
--   デモアカウントの COMPUTE_WH に既存のリソースモニターがある場合、
--   上書きすると他の用途に影響するため既定では実行しない。
--   Trialなど専用アカウントでだけ、コメントを外して使う。
-- =============================================================================
-- CREATE RESOURCE MONITOR IF NOT EXISTS SWT_HANDSON_RM
--   WITH CREDIT_QUOTA = 100
--   TRIGGERS
--     ON 80  PERCENT DO NOTIFY
--     ON 95  PERCENT DO SUSPEND
--     ON 100 PERCENT DO SUSPEND_IMMEDIATE;
-- ALTER WAREHOUSE COMPUTE_WH SET RESOURCE MONITOR = SWT_HANDSON_RM;


-- =============================================================================
-- [8] 判定
--
--   [2] が FAIL のアカウントでは付録F（マスキング・行アクセスポリシー）が動かない。
--   [5] の WARN は了承できれば進めてよい。
--   [1] と [6] の WARN は動作はするが所要時間が伸びる。
-- =============================================================================
SELECT '[8] 判定' AS check_name,
       '[2] が PASS、[5] を確認したうえで 01_setup.sql に進む' AS note;
