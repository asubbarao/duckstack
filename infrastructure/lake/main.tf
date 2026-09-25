terraform {
  required_version = ">= 1.5, < 2.0"
  required_providers {
    aws = { source = "hashicorp/aws", version = ">= 6.0, < 7.0" }
  }
  backend "s3" {
    bucket         = "inframe-terraform-state-785081088852"
    key            = "developer-lake/terraform.tfstate"
    region         = "us-west-2"
    dynamodb_table = "inframe-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region              = "us-west-2"
  allowed_account_ids = ["785081088852"]
}

resource "aws_s3_bucket" "lake" {
  bucket = "inframe-duckstack-785081088852"
  tags = {
    system      = "duckstack"
    purpose     = "developer-shared-artifacts"
    environment = "shared-dev"
  }
  lifecycle { prevent_destroy = true }
}

resource "aws_s3_bucket_public_access_block" "lake" {
  bucket                  = aws_s3_bucket.lake.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "lake" {
  bucket = aws_s3_bucket.lake.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_ownership_controls" "lake" {
  bucket = aws_s3_bucket.lake.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_policy" "lake" {
  bucket = aws_s3_bucket.lake.id
  policy = file("${path.module}/../../server/lake_s3_policy.json")
}

import {
  to = aws_s3_bucket.lake
  id = "inframe-duckstack-785081088852"
}
import {
  to = aws_s3_bucket_public_access_block.lake
  id = "inframe-duckstack-785081088852"
}
import {
  to = aws_s3_bucket_versioning.lake
  id = "inframe-duckstack-785081088852"
}
import {
  to = aws_s3_bucket_ownership_controls.lake
  id = "inframe-duckstack-785081088852"
}
import {
  to = aws_s3_bucket_policy.lake
  id = "inframe-duckstack-785081088852"
}

output "bucket" { value = aws_s3_bucket.lake.id }
