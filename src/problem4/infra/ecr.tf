# ECR's own grant on this key covers encrypt on push and decrypt on pull, so
# pullers in other accounts need no KMS permission. The encryption setting is
# fixed when the repository is created.
resource "aws_kms_key" "ecr" {
  count = var.create_ecr_repository ? 1 : 0

  description             = "Encrypts the ${var.ecr_repository_name} ECR repository"
  enable_key_rotation     = true
  deletion_window_in_days = 30
}

resource "aws_kms_alias" "ecr" {
  count = var.create_ecr_repository ? 1 : 0

  name          = "alias/ecr-${var.ecr_repository_name}"
  target_key_id = aws_kms_key.ecr[0].key_id
}

resource "aws_ecr_repository" "this" {
  count = var.create_ecr_repository ? 1 : 0

  name                 = var.ecr_repository_name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.ecr[0].arn
  }
}

data "aws_iam_policy_document" "ecr_cross_account_pull" {
  count = local.holds_ecr && length(var.ecr_pull_account_ids) > 0 ? 1 : 0

  statement {
    sid = "PullFromOtherAccountInstances"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]

    principals {
      type        = "AWS"
      identifiers = [for id in var.ecr_pull_account_ids : "arn:${local.partition}:iam::${id}:root"]
    }

    # The account principal plus this condition admits only the instance role, and
    # does not require that role to exist before the policy is applied.
    condition {
      test     = "ArnEquals"
      variable = "aws:PrincipalArn"
      values   = [for id in var.ecr_pull_account_ids : "arn:${local.partition}:iam::${id}:role/${var.app_tag}-instance"]
    }
  }
}

resource "aws_ecr_repository_policy" "cross_account_pull" {
  count = local.holds_ecr && length(var.ecr_pull_account_ids) > 0 ? 1 : 0

  repository = var.ecr_repository_name
  policy     = data.aws_iam_policy_document.ecr_cross_account_pull[0].json

  depends_on = [aws_ecr_repository.this]
}
