terraform {
  required_version = ">= 1.5"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.region
}

data "aws_caller_identity" "current" {}

variable "region" {
  type    = string
  default = "ap-northeast-1"
}

variable "bucket_name" {
  type = string
}

variable "role_name" {
  type    = string
  default = "snowflake-meeting-transcripts-role"
}

# 2回目のapplyで設定する(DESC INTEGRATIONの値)。1回目は空のまま
variable "snowflake_iam_user_arn" {
  type    = string
  default = ""
}

variable "snowflake_external_id" {
  type    = string
  default = ""
}

# SHOW PIPES の notification_channel (SQS ARN)。3回目のapplyで設定する
variable "snowpipe_sqs_arn" {
  type    = string
  default = ""
}

locals {
  prefix          = "transcripts/"
  second_phase    = var.snowflake_iam_user_arn != "" && var.snowflake_external_id != ""
  trust_principal = local.second_phase ? var.snowflake_iam_user_arn : "arn:aws:iam::${data.aws_caller_identity.current.account_id}:root"
}

resource "aws_s3_bucket" "transcripts" {
  bucket        = var.bucket_name
  force_destroy = true # 検証用。クリーンアップを楽にする
}

resource "aws_s3_bucket_public_access_block" "transcripts" {
  bucket                  = aws_s3_bucket.transcripts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

data "aws_iam_policy_document" "trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "AWS"
      identifiers = [local.trust_principal]
    }
    dynamic "condition" {
      for_each = local.second_phase ? [1] : []
      content {
        test     = "StringEquals"
        variable = "sts:ExternalId"
        values   = [var.snowflake_external_id]
      }
    }
  }
}

resource "aws_iam_role" "snowflake" {
  name               = var.role_name
  assume_role_policy = data.aws_iam_policy_document.trust.json
}

data "aws_iam_policy_document" "s3_read" {
  statement {
    actions   = ["s3:GetObject", "s3:GetObjectVersion"]
    resources = ["${aws_s3_bucket.transcripts.arn}/${local.prefix}*"]
  }
  statement {
    actions   = ["s3:ListBucket", "s3:GetBucketLocation"]
    resources = [aws_s3_bucket.transcripts.arn]
    condition {
      test     = "StringLike"
      variable = "s3:prefix"
      values   = ["${local.prefix}*"]
    }
  }
}

resource "aws_iam_role_policy" "s3_read" {
  name   = "s3-read-transcripts"
  role   = aws_iam_role.snowflake.id
  policy = data.aws_iam_policy_document.s3_read.json
}

# Snowpipe auto-ingest 用のS3イベント通知(Snowflake管理のSQSへ)
resource "aws_s3_bucket_notification" "snowpipe" {
  count  = var.snowpipe_sqs_arn != "" ? 1 : 0
  bucket = aws_s3_bucket.transcripts.id

  queue {
    queue_arn     = var.snowpipe_sqs_arn
    events        = ["s3:ObjectCreated:*"]
    filter_prefix = local.prefix
    filter_suffix = ".md"
  }
}

output "role_arn" {
  value = aws_iam_role.snowflake.arn
}

output "bucket_name" {
  value = aws_s3_bucket.transcripts.bucket
}
