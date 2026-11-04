# Uploaded images must survive Fargate replacement. S3 remains private; only the image CDN reads it.
resource "aws_s3_bucket" "images" {
  for_each      = local.environments
  bucket        = "burger-${each.key}-images-${var.account_id}-${var.region}"
  force_destroy = false
}
resource "aws_s3_bucket_public_access_block" "images" {
  for_each                = local.environments
  bucket                  = aws_s3_bucket.images[each.key].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}
resource "aws_s3_bucket_server_side_encryption_configuration" "images" {
  for_each = local.environments
  bucket   = aws_s3_bucket.images[each.key].id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}
resource "aws_cloudfront_origin_access_control" "images" {
  for_each                          = local.environments
  name                              = "burger-${each.key}-images"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}
resource "aws_cloudfront_distribution" "images" {
  for_each        = local.environments
  enabled         = true
  is_ipv6_enabled = true
  price_class     = "PriceClass_200"
  origin {
    domain_name              = aws_s3_bucket.images[each.key].bucket_regional_domain_name
    origin_id                = "images"
    origin_access_control_id = aws_cloudfront_origin_access_control.images[each.key].id
  }
  default_cache_behavior {
    target_origin_id       = "images"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    compress               = true
    min_ttl                = 0
    default_ttl            = 86400
    max_ttl                = 31536000
    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }
  }
  restrictions {
    geo_restriction { restriction_type = "none" }
  }
  viewer_certificate { cloudfront_default_certificate = true }
}
resource "aws_s3_bucket_policy" "images" {
  for_each = local.environments
  bucket   = aws_s3_bucket.images[each.key].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "cloudfront.amazonaws.com" }
      Action    = "s3:GetObject"
      Resource  = "${aws_s3_bucket.images[each.key].arn}/burger/*"
      Condition = { StringEquals = { "AWS:SourceArn" = aws_cloudfront_distribution.images[each.key].arn } }
    }]
  })
}
