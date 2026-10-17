USE ROLE ACCOUNTADMIN;
USE SCHEMA MEETING_DB.APP;

CREATE OR REPLACE STREAM RAW_TRANSCRIPTS_STREAM ON TABLE RAW_TRANSCRIPTS APPEND_ONLY = TRUE;

CREATE OR REPLACE TASK ANALYZE_TRANSCRIPTS_TASK
  WAREHOUSE = MEETING_WH
  SCHEDULE = '1 MINUTE'
  WHEN SYSTEM$STREAM_HAS_DATA('MEETING_DB.APP.RAW_TRANSCRIPTS_STREAM')
AS
EXECUTE IMMEDIATE $$
BEGIN
  -- 1. ストリームを読んで一時テーブルへ。同じファイルが複数回入っていたら最新の1行だけ使う
  CREATE OR REPLACE TEMPORARY TABLE TMP_NEW AS
    SELECT FILE_PATH, CONTENT FROM RAW_TRANSCRIPTS_STREAM
    QUALIFY ROW_NUMBER() OVER (PARTITION BY FILE_PATH ORDER BY LOADED_AT DESC) = 1;

  -- 2. LLM呼び出し(1ファイル1回)
  CREATE OR REPLACE TEMPORARY TABLE TMP_RESULT AS
  WITH ctx AS (
    SELECT
      (SELECT LISTAGG('- ' || TAG_CODE || ': ' || TAG_NAME || '(' || COALESCE(DESCRIPTION,'') || ' / 別名: ' || COALESCE(ARRAY_TO_STRING(ALIASES, ','),'') || ')', '\n')
         WITHIN GROUP (ORDER BY TAG_CODE) FROM TAG_MASTER WHERE IS_ACTIVE) AS TAGS_TXT,
      (SELECT LISTAGG('- ' || PROJECT_CODE || ': ' || PROJECT_NAME || '(' || COALESCE(DESCRIPTION,'') || ' / キーワード: ' || COALESCE(ARRAY_TO_STRING(KEYWORDS, ','),'') || ')', '\n')
         WITHIN GROUP (ORDER BY PROJECT_CODE) FROM PROJECT_MASTER WHERE IS_ACTIVE) AS PROJECTS_TXT,
      (SELECT LISTAGG('- ' || STATUS_CODE || ': ' || STATUS_NAME || '(' || COALESCE(DESCRIPTION,'') || ')', '\n')
         WITHIN GROUP (ORDER BY STATUS_CODE) FROM STATUS_MASTER) AS STATUS_TXT
  )
  SELECT
    n.FILE_PATH,
    AI_COMPLETE(
      model => 'claude-sonnet-4-6',
      prompt => CONCAT(
        'あなたは会議議事録を分類するアシスタントです。以下のマスターに基づいて議事録を分析してください。\n',
        '## ルール\n',
        '- tags は「タグマスター」の TAG_CODE のみを使う。議事録で実質的に議論された技術のみ(言及だけは除く)。最大5個。\n',
        '- マスターに無いが重要な技術が議論されている場合は unknown_tags に自由記述で入れる。\n',
        '- project_code は「プロジェクトマスター」の PROJECT_CODE から1つ。判断できない場合は null。\n',
        '- status_code は「状況マスター」の STATUS_CODE から1つ。判断できない場合は UNKNOWN。\n',
        '- evidence には判断の根拠となる議事録内の文を1〜3個、原文から一字一句そのままコピーして配列で入れる。括弧・話者名・記号を付け足したり、複数の文をつなげたりしない。\n',
        '- summary は日本語で2文以内。\n\n',
        '## タグマスター\n', c.TAGS_TXT, '\n\n',
        '## プロジェクトマスター\n', c.PROJECTS_TXT, '\n\n',
        '## 状況マスター\n', c.STATUS_TXT, '\n\n',
        '## 議事録\n', n.CONTENT),
      response_format => {
        'type': 'json',
        'schema': {
          'type': 'object',
          'properties': {
            'summary':      {'type': 'string'},
            'project_code': {'type': ['string','null']},
            'status_code':  {'type': 'string'},
            'tags':         {'type': 'array', 'items': {'type': 'string'}},
            'unknown_tags': {'type': 'array', 'items': {'type': 'string'}},
            'evidence':     {'type': 'array', 'items': {'type': 'string'}}
          },
          'required': ['summary','project_code','status_code','tags','unknown_tags','evidence'],
          'additionalProperties': false
        }
      }
    ) AS R
  FROM TMP_NEW n CROSS JOIN ctx c;

  -- 3. メタデータ(マスターに無い値はNULL化し、生の値は残す)
  MERGE INTO TRANSCRIPT_METADATA t
  USING (
    SELECT
      r.FILE_PATH,
      pm.PROJECT_CODE,
      r.R:project_code::STRING AS PROJECT_RAW,
      COALESCE(sm.STATUS_CODE, 'UNKNOWN') AS STATUS_CODE,
      r.R:summary::STRING AS SUMMARY,
      r.R:evidence::ARRAY AS EVIDENCE,
      r.R AS RAW_RESPONSE
    FROM TMP_RESULT r
    LEFT JOIN PROJECT_MASTER pm ON pm.PROJECT_CODE = r.R:project_code::STRING
    LEFT JOIN STATUS_MASTER sm ON sm.STATUS_CODE = r.R:status_code::STRING
    WHERE r.R IS NOT NULL
  ) s ON t.FILE_PATH = s.FILE_PATH
  WHEN MATCHED THEN UPDATE SET PROJECT_CODE = s.PROJECT_CODE, PROJECT_RAW = s.PROJECT_RAW,
    STATUS_CODE = s.STATUS_CODE, SUMMARY = s.SUMMARY, EVIDENCE = s.EVIDENCE,
    RAW_RESPONSE = s.RAW_RESPONSE, MODEL_NAME = 'claude-sonnet-4-6', ANALYZED_AT = CURRENT_TIMESTAMP()
  WHEN NOT MATCHED THEN INSERT (FILE_PATH, PROJECT_CODE, PROJECT_RAW, STATUS_CODE, SUMMARY, EVIDENCE, RAW_RESPONSE, MODEL_NAME)
    VALUES (s.FILE_PATH, s.PROJECT_CODE, s.PROJECT_RAW, s.STATUS_CODE, s.SUMMARY, s.EVIDENCE, s.RAW_RESPONSE, 'claude-sonnet-4-6');

  -- 4. タグ(多対多)。マスターに存在するものだけ展開。再解析に備えて一度削除
  DELETE FROM TRANSCRIPT_TAG WHERE FILE_PATH IN (SELECT FILE_PATH FROM TMP_RESULT WHERE R IS NOT NULL);
  INSERT INTO TRANSCRIPT_TAG (FILE_PATH, TAG_CODE)
    SELECT DISTINCT r.FILE_PATH, tm.TAG_CODE
    FROM TMP_RESULT r, LATERAL FLATTEN(input => r.R:tags) f
    JOIN TAG_MASTER tm ON tm.TAG_CODE = f.value::STRING AND tm.IS_ACTIVE;

  -- 5. マスター外のタグ候補(unknown_tags + tagsに入っていたがマスターに無いもの)
  DELETE FROM UNKNOWN_TAG_CANDIDATE WHERE FILE_PATH IN (SELECT FILE_PATH FROM TMP_RESULT WHERE R IS NOT NULL);
  INSERT INTO UNKNOWN_TAG_CANDIDATE (FILE_PATH, TAG_RAW)
    SELECT r.FILE_PATH, f.value::STRING
    FROM TMP_RESULT r, LATERAL FLATTEN(input => r.R:unknown_tags) f
    UNION
    SELECT r.FILE_PATH, f.value::STRING
    FROM TMP_RESULT r, LATERAL FLATTEN(input => r.R:tags) f
    WHERE f.value::STRING NOT IN (SELECT TAG_CODE FROM TAG_MASTER);
END;
$$;

ALTER TASK ANALYZE_TRANSCRIPTS_TASK RESUME;
