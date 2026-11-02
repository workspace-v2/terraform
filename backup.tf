# ---------------------------------------------------------------------------
# 모니터링 데이터 백업용 S3 버킷 (Prometheus TSDB, Grafana DB)
#   - 버전 관리: 같은 이름으로 덮어써도 이전 백업이 남는다.
#   - 암호화(SSE-S3), 퍼블릭 접근 차단, prevent_destroy (terraform 으로 지워지지 않게).
#   - 업로드/다운로드: scripts/monitoring-backup.sh, monitoring-restore.sh (SSM 으로 모니터링 서버에서 실행)
# ---------------------------------------------------------------------------
resource "aws_s3_bucket" "monitoring_backup" {
  bucket = "${var.name_prefix}-monitoring-backup-${local.account_id}"

  tags = { Name = "${var.name_prefix}-monitoring-backup" }

  lifecycle {
    prevent_destroy = true
  }
}

resource "aws_s3_bucket_versioning" "monitoring_backup" {
  bucket = aws_s3_bucket.monitoring_backup.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "monitoring_backup" {
  bucket = aws_s3_bucket.monitoring_backup.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "monitoring_backup" {
  bucket                  = aws_s3_bucket.monitoring_backup.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

output "monitoring_backup_bucket" {
  description = "모니터링 백업 S3 버킷 (scripts/monitoring-backup.sh)"
  value       = aws_s3_bucket.monitoring_backup.bucket
}

# EC2 공통 역할(base)에 이 버킷만 읽고 쓰는 권한. 모니터링 서버가 aws-cli 컨테이너로 업로드/다운로드한다.
data "aws_iam_policy_document" "monitoring_backup" {
  statement {
    sid       = "ListBackupBucket"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.monitoring_backup.arn]
  }

  statement {
    sid       = "ReadWriteBackupObjects"
    actions   = ["s3:PutObject", "s3:GetObject"]
    resources = ["${aws_s3_bucket.monitoring_backup.arn}/monitoring/*"]
  }
}

resource "aws_iam_role_policy" "base_monitoring_backup" {
  name   = "monitoring-backup"
  role   = aws_iam_role.base.id
  policy = data.aws_iam_policy_document.monitoring_backup.json
}
