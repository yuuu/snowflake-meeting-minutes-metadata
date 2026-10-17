USE ROLE ACCOUNTADMIN;
CREATE DATABASE IF NOT EXISTS MEETING_DB;
CREATE SCHEMA IF NOT EXISTS MEETING_DB.APP;
USE SCHEMA MEETING_DB.APP;

CREATE WAREHOUSE IF NOT EXISTS MEETING_WH
  WAREHOUSE_SIZE = 'XSMALL'
  AUTO_SUSPEND = 60
  AUTO_RESUME = TRUE
  INITIALLY_SUSPENDED = TRUE;

-- ===== マスター =====
CREATE OR REPLACE TABLE TAG_MASTER (
  TAG_CODE    VARCHAR      NOT NULL PRIMARY KEY,  -- 例: aws-lambda
  TAG_NAME    VARCHAR      NOT NULL,              -- 表示名
  CATEGORY    VARCHAR,                            -- 例: Cloud / Frontend / Backend / DB / Security
  DESCRIPTION VARCHAR,                            -- LLMへ渡す説明
  ALIASES     ARRAY,                              -- 表記ゆれ・略称
  IS_ACTIVE   BOOLEAN      DEFAULT TRUE
);

CREATE OR REPLACE TABLE PROJECT_MASTER (
  PROJECT_CODE VARCHAR     NOT NULL PRIMARY KEY,  -- 例: PRJ-001
  PROJECT_NAME VARCHAR     NOT NULL,
  DESCRIPTION  VARCHAR,
  KEYWORDS     ARRAY,                             -- 判定のヒント
  IS_ACTIVE    BOOLEAN     DEFAULT TRUE
);

CREATE OR REPLACE TABLE STATUS_MASTER (
  STATUS_CODE VARCHAR NOT NULL PRIMARY KEY,
  STATUS_NAME VARCHAR NOT NULL,
  DESCRIPTION VARCHAR                              -- 判定の目安
);

INSERT INTO TAG_MASTER (TAG_CODE, TAG_NAME, CATEGORY, DESCRIPTION, ALIASES)
SELECT $1,$2,$3,$4,PARSE_JSON($5) FROM VALUES
 ('aws-lambda','AWS Lambda','Cloud','サーバーレス関数実行サービス','["Lambda","ラムダ"]'),
 ('aws-s3','Amazon S3','Cloud','オブジェクトストレージ','["S3"]'),
 ('terraform','Terraform','IaC','HashiCorp製のIaCツール','["tf"]'),
 ('kubernetes','Kubernetes','Infra','コンテナオーケストレーション','["k8s","EKS"]'),
 ('react','React','Frontend','UIライブラリ','["React.js"]'),
 ('nextjs','Next.js','Frontend','Reactベースのフレームワーク','["Next"]'),
 ('typescript','TypeScript','Language','型付きJavaScript','["TS"]'),
 ('ruby-on-rails','Ruby on Rails','Backend','RubyのWebフレームワーク','["Rails"]'),
 ('postgresql','PostgreSQL','DB','RDB','["Postgres","Aurora PostgreSQL"]'),
 ('snowflake','Snowflake','DataPlatform','クラウドデータプラットフォーム','["スノーフレーク"]'),
 ('oauth','OAuth/OIDC','Security','認可・認証プロトコル','["OIDC","SSO"]'),
 ('github-actions','GitHub Actions','CI/CD','CI/CDサービス','["GHA"]'),
 ('web-performance','Webパフォーマンス','Frontend','表示速度・Core Web Vitals改善','["LCP","CWV"]'),
 ('observability','オブザーバビリティ','Ops','監視・ログ・トレース','["Datadog","CloudWatch","監視"]');

INSERT INTO PROJECT_MASTER (PROJECT_CODE, PROJECT_NAME, DESCRIPTION, KEYWORDS)
SELECT $1,$2,$3,PARSE_JSON($4) FROM VALUES
 ('PRJ-001','ECサイトリニューアル','既存ECサイトをNext.jsとAPIへ刷新する','["EC","カート","決済","リニューアル"]'),
 ('PRJ-002','社内データ分析基盤','SnowflakeによるKPI可視化基盤の構築','["BI","ダッシュボード","データ基盤","KPI"]'),
 ('PRJ-003','顧客向けモバイルAPI','モバイルアプリ向けRails APIのAWS移行','["モバイル","API","Lambda","Rails"]'),
 ('PRJ-004','認証基盤統合','複数サービスのSSO統合','["SSO","ログイン","IdP"]');

INSERT INTO STATUS_MASTER VALUES
 ('NOT_STARTED','未着手','着手前・計画段階・キックオフ'),
 ('IN_PROGRESS','進行中','作業が計画通り、または多少の課題はあるが進んでいる'),
 ('BLOCKED','ブロック中','外部要因や未解決の課題で作業が止まっている'),
 ('ON_HOLD','保留','意図的に中断・優先度下げ'),
 ('COMPLETED','完了','リリース済み・作業完了を宣言した'),
 ('UNKNOWN','不明','議事録から判断できない');

-- ===== 取り込み先・メタデータ =====
CREATE OR REPLACE TABLE RAW_TRANSCRIPTS (
  FILE_PATH   VARCHAR,
  CONTENT     VARCHAR,       -- ファイル全体
  LOADED_AT   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);

CREATE OR REPLACE TABLE TRANSCRIPT_METADATA (
  FILE_PATH       VARCHAR NOT NULL,
  PROJECT_CODE    VARCHAR,           -- マスターに存在する場合のみ。無ければNULL
  PROJECT_RAW     VARCHAR,           -- LLMが返した生の値(マスター外の検知用)
  STATUS_CODE     VARCHAR,
  SUMMARY         VARCHAR,
  EVIDENCE        ARRAY,             -- 判断の根拠となった発言(原文の1文ずつ)
  RAW_RESPONSE    VARIANT,           -- LLMの生JSON(デバッグ・再正規化用)
  MODEL_NAME      VARCHAR,
  ANALYZED_AT     TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP(),
  PRIMARY KEY (FILE_PATH)
);

-- 多対多: 議事録 x タグ
CREATE OR REPLACE TABLE TRANSCRIPT_TAG (
  FILE_PATH VARCHAR NOT NULL,
  TAG_CODE  VARCHAR NOT NULL,
  PRIMARY KEY (FILE_PATH, TAG_CODE)
);

-- マスターに無かったタグ候補(マスター追加の検討用)
CREATE OR REPLACE TABLE UNKNOWN_TAG_CANDIDATE (
  FILE_PATH  VARCHAR NOT NULL,
  TAG_RAW    VARCHAR NOT NULL,
  FOUND_AT   TIMESTAMP_LTZ DEFAULT CURRENT_TIMESTAMP()
);
