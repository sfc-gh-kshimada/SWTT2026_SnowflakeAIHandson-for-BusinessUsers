-- =============================================================================
-- 初めてのSnowflake AI 〜ビジネスユーザ編〜 （社内版） 撤収
--
--   01_setup.sql が作ったものを外す。アカウントの共有設定に触る順に並べている。
--   DROP は取り消しができないため、既定では最後の DROP DATABASE を
--   コメントアウトしてある。中身を確認してから外すこと。
-- =============================================================================
USE ROLE ACCOUNTADMIN;


-- -----------------------------------------------------------------------------
-- 1. CoWork から Agent を外す
--    同じアカウントの他ユーザーの CoWork にも出ているため最初に外す。
--    DROP AGENT 句は未検証。エラーは握りつぶすため、CoWork に Agent が残る場合は
--    4. の DROP DATABASE で Agent ごと消すか、Snowsight の AI & ML > Agents で外す。
-- -----------------------------------------------------------------------------
EXECUTE IMMEDIATE $$
BEGIN
  ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
    DROP AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_1;
  ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
    DROP AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_2;
  ALTER SNOWFLAKE INTELLIGENCE SNOWFLAKE_INTELLIGENCE_OBJECT_DEFAULT
    DROP AGENT SWT_CW_HANDSON.AI.BUSINESS_DECISION_AGENT_3;
EXCEPTION
  WHEN OTHER THEN
    NULL;  -- 追加されていなければ無視
END;
$$;


-- -----------------------------------------------------------------------------
-- 2. Web検索を元に戻す（任意）
--    01_setup.sql を流す前から TRUE だった場合は実行しないこと。
-- -----------------------------------------------------------------------------
-- ALTER ACCOUNT SET ENABLE_CORTEX_WEBSEARCH = FALSE;


-- -----------------------------------------------------------------------------
-- 3. ウェアハウスを停止
-- -----------------------------------------------------------------------------
ALTER WAREHOUSE IF EXISTS COMPUTE_WH SUSPEND;


-- -----------------------------------------------------------------------------
-- 4. ロールとデータベースの削除（取り消し不可・確認してから外す）
--    DROP DATABASE で Agent・Cortex Search・Semantic View・ステージ上のPDFも消える。
-- -----------------------------------------------------------------------------
-- DROP ROLE IF EXISTS SWT_PARTICIPANT;
-- DROP ROLE IF EXISTS SWT_DATA_STEWARD;
-- DROP DATABASE IF EXISTS SWT_CW_HANDSON;
