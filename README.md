# snowflake-meeting-minutes-metadata

Markdownで書いた会議の議事録をS3に置くだけで、Snowflake Cortex AI(`AI_COMPLETE` の構造化出力)が次のメタデータを付ける仕組みのサンプルです。

- 技術タグ(タグマスターにあるもののみ。複数)
- プロジェクト(プロジェクトマスターから1つ。該当なしもあり)
- 状況(進行中 / ブロック中 / 完了 など)
- 要約と、判断の根拠になった文

解説記事: https://zenn.dev/fusic/articles/snowflake-ai-parse-document-minutes

## 構成

```
S3 (transcripts/*.md)
  └─ S3イベント通知 → Snowpipe → RAW_TRANSCRIPTS (1ファイル=1行)
                                   └─ Stream → Task (AI_COMPLETE)
                                                 ├─ TRANSCRIPT_METADATA
                                                 ├─ TRANSCRIPT_TAG (多対多)
                                                 └─ UNKNOWN_TAG_CANDIDATE
```

| パス | 内容 |
| --- | --- |
| `terraform/main.tf` | S3バケット、IAMロール、S3イベント通知 |
| `sql/01_base.sql` | DB・ウェアハウス・マスター・結果テーブル |
| `sql/02_integration.sql` | Storage Integration |
| `sql/03_stage_pipe.sql` | ファイルフォーマット・ステージ・Snowpipe |
| `sql/04_pipeline.sql` | Stream・Task(LLM解析) |
| `sql/05_queries.sql` | 動作確認・活用・再解析・コスト確認のクエリ |
| `sql/99_cleanup.sql` | Snowflake側の後片付け |
| `samples/*.md` | 検証に使った議事録 |
| `scripts/run_sql.sh` | SQL中の `${BUCKET}` `${ROLE_ARN}` を置き換えて `snow sql` で実行する |

## 前提

- Snowflakeアカウントが AWS 上のリージョンにあること
- `claude-sonnet-4-6` が使えること(リージョンによってはクロスリージョン推論 `CORTEX_ENABLED_CROSS_REGION` の有効化が必要)
- `ACCOUNTADMIN` ロールで操作します(検証用)
- [Snowflake CLI](https://docs.snowflake.com/ja/developer-guide/snowflake-cli/index)、Terraform 1.5以上、AWS CLI、`envsubst`(gettext)

検証環境: `AWS_AP_NORTHEAST_1`、Snowflake CLI 3.27.0、Terraform 1.16.2

## 手順

SnowflakeとAWSがお互いの情報を必要とするため、`terraform apply` を3回に分けて実行します。

```sh
export SF_CONN=<Snowflake CLIのコネクション名>
export BUCKET=meeting-transcripts-$(aws sts get-caller-identity --query Account --output text)-demo
```

### 1. マスターとテーブル

```sh
./scripts/run_sql.sh sql/01_base.sql
```

### 2. Terraform 1回目(バケットとIAMロール)

```sh
cd terraform
terraform init
terraform apply -var "bucket_name=${BUCKET}"
export ROLE_ARN=$(terraform output -raw role_arn)
cd ..
```

### 3. Storage Integration

```sh
./scripts/run_sql.sh sql/02_integration.sql
```

`DESC INTEGRATION` の `STORAGE_AWS_IAM_USER_ARN` と `STORAGE_AWS_EXTERNAL_ID` を控えます。

```sh
export SF_IAM_USER_ARN=<STORAGE_AWS_IAM_USER_ARN>
export SF_EXTERNAL_ID=<STORAGE_AWS_EXTERNAL_ID>
```

> [!WARNING]
> `02_integration.sql` を再実行すると外部IDが変わり、IAMロールの信頼ポリシーと食い違います。再実行した場合は、2回目の `apply` からやり直してください。

### 4. Terraform 2回目(信頼ポリシーの差し替え)

```sh
cd terraform
terraform apply -var "bucket_name=${BUCKET}" \
  -var "snowflake_iam_user_arn=${SF_IAM_USER_ARN}" \
  -var "snowflake_external_id=${SF_EXTERNAL_ID}"
cd ..
```

### 5. ステージとSnowpipe

```sh
./scripts/run_sql.sh sql/03_stage_pipe.sql
```

`SHOW PIPES` の `notification_channel` を控えます。

```sh
export PIPE_SQS_ARN=<notification_channel>
```

### 6. Terraform 3回目(S3イベント通知)

```sh
cd terraform
terraform apply -var "bucket_name=${BUCKET}" \
  -var "snowflake_iam_user_arn=${SF_IAM_USER_ARN}" \
  -var "snowflake_external_id=${SF_EXTERNAL_ID}" \
  -var "snowpipe_sqs_arn=${PIPE_SQS_ARN}"
cd ..
```

### 7. Stream と Task

```sh
./scripts/run_sql.sh sql/04_pipeline.sql
```

### 8. 議事録をアップロードする

```sh
aws s3 cp samples/ "s3://${BUCKET}/transcripts/" --recursive --exclude "*" --include "*.md"
```

1〜2分後に、`sql/05_queries.sql` のクエリで結果を確認できます。

## サンプル議事録

`samples/` の議事録と、`sql/01_base.sql` のマスターデータ(プロジェクト、人名、数値など)は、全て検証用に作成した架空のものです。実在の組織・人物・案件とは関係ありません。

| ファイル | 想定したプロジェクト | 想定した状況 | 想定したタグ |
| --- | --- | --- | --- |
| `meeting_2026-09-30_ec_cart.md` | PRJ-001 | IN_PROGRESS | nextjs, typescript, web-performance, aws-s3 |
| `meeting_2026-10-01_data_platform.md` | PRJ-002 | BLOCKED | snowflake, terraform, github-actions, postgresql |
| `meeting_2026-10-01_dev_weekly.md` | (判断が分かれる例) | (判断が分かれる例) | (マスター外の技術のみ) |
| `meeting_2026-10-02_auth_sso.md` | PRJ-004 | COMPLETED | oauth, kubernetes, observability |
| `meeting_2026-10-02_study_session.md` | なし | NOT_STARTED | なし(Rust、WebAssemblyはマスター外) |

## 後片付け

```sh
./scripts/run_sql.sh sql/99_cleanup.sql

cd terraform
terraform destroy -var "bucket_name=${BUCKET}" \
  -var "snowflake_iam_user_arn=${SF_IAM_USER_ARN}" \
  -var "snowflake_external_id=${SF_EXTERNAL_ID}" \
  -var "snowpipe_sqs_arn=${PIPE_SQS_ARN}"
```

## License

MIT
