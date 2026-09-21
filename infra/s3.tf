# ---------------------------------------------------------------------------
# Raw landing bucket.
#
# Today the loader writes the whole API payload into a jsonb column. On AWS the
# payload goes to S3 and Postgres keeps a pointer, which is the conventional
# split for a reason: object storage is about 25x cheaper per GB than RDS
# storage, and RDS storage can only ever grow -- you cannot shrink an RDS
# volume once it has expanded.
#
# At this data volume the saving is pennies. The reason to do it is that the
# alternative teaches the wrong instinct.
# ---------------------------------------------------------------------------

resource "aws_s3_bucket" "raw" {
  # Bucket names are globally unique across all AWS customers, so the account
  # id is appended rather than hoping "cairo-air-quality-raw" is free.
  bucket = "${var.project_name}-raw-${data.aws_caller_identity.current.account_id}"
}

data "aws_caller_identity" "current" {}

resource "aws_s3_bucket_public_access_block" "raw" {
  bucket = aws_s3_bucket.raw.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  rule {
    # SSE-S3 rather than SSE-KMS. KMS would add about $1/month for the key plus
    # per-request charges, to protect public air quality readings from nobody.
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "raw" {
  bucket = aws_s3_bucket.raw.id

  # Aborts uploads that were started and never finished. Incomplete multipart
  # uploads are invisible in the console and billed indefinitely -- a genuine
  # cause of mystery S3 bills.
  rule {
    id     = "abort-incomplete-uploads"
    status = "Enabled"

    filter {}

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }

  # No storage-class tiering rule. At ~30 KB/day, transitioning to Glacier
  # would save a fraction of a cent and add a retrieval delay to the one thing
  # the raw layer exists for: being replayable on demand. Tiering here would be
  # cargo cult.
}
