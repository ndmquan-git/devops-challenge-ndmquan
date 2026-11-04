resource "aws_ecr_repository" "this" {
  count = var.create_ecr_repository ? 1 : 0

  name                 = var.ecr_repository_name
  image_tag_mutability = "IMMUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
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
