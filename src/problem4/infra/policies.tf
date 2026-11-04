data "aws_iam_policy_document" "publish" {
  count = local.holds_ecr ? 1 : 0

  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPush"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:PutImage",
      "ecr:UploadLayerPart",
    ]
    resources = [local.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "publish" {
  count = local.holds_ecr ? 1 : 0

  name   = "ecr-push"
  role   = aws_iam_role.publish[0].id
  policy = data.aws_iam_policy_document.publish[0].json
}

data "aws_iam_policy_document" "deploy" {
  for_each = var.environments

  statement {
    sid       = "FindInstances"
    actions   = ["ec2:DescribeInstances"]
    resources = ["*"]
  }

  statement {
    sid = "TargetGroupMembership"
    actions = [
      "elasticloadbalancing:RegisterTargets",
      "elasticloadbalancing:DeregisterTargets",
    ]
    resources = [each.value.target_group_arn]
  }

  statement {
    sid       = "TargetHealth"
    actions   = ["elasticloadbalancing:DescribeTargetHealth"]
    resources = ["*"]
  }

  statement {
    sid       = "RunShellScriptDocument"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${local.partition}:ssm:${var.aws_region}::document/AWS-RunShellScript"]
  }

  statement {
    sid       = "RunShellScriptOnTaggedInstances"
    actions   = ["ssm:SendCommand"]
    resources = ["arn:${local.partition}:ec2:${var.aws_region}:${local.account_id}:instance/*"]

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/App"
      values   = [var.app_tag]
    }

    condition {
      test     = "StringEquals"
      variable = "ssm:resourceTag/Env"
      values   = [each.key]
    }
  }

  statement {
    sid       = "CommandStatus"
    actions   = ["ssm:GetCommandInvocation"]
    resources = ["*"]
  }

  statement {
    sid = "FrontendBucket"
    actions = [
      "s3:ListBucket",
      "s3:ListBucketVersions",
    ]
    resources = ["arn:${local.partition}:s3:::${each.value.frontend_bucket}"]
  }

  statement {
    sid = "FrontendObjects"
    actions = [
      "s3:PutObject",
      "s3:GetObject",
      "s3:GetObjectVersion",
    ]
    resources = ["arn:${local.partition}:s3:::${each.value.frontend_bucket}/*"]
  }

  statement {
    sid       = "FrontendInvalidation"
    actions   = ["cloudfront:CreateInvalidation"]
    resources = ["arn:${local.partition}:cloudfront::${local.account_id}:distribution/${each.value.cloudfront_distribution_id}"]
  }

  statement {
    sid    = "DenyEscalationAndTeardown"
    effect = "Deny"
    actions = [
      "iam:*",
      "sts:AssumeRole",
      "ec2:TerminateInstances",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "deploy" {
  for_each = var.environments

  name   = "deploy-${each.key}"
  role   = aws_iam_role.deploy[each.key].id
  policy = data.aws_iam_policy_document.deploy[each.key].json
}

data "aws_iam_policy_document" "instance_ecr_pull" {
  statement {
    sid       = "EcrLogin"
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }

  statement {
    sid = "EcrPull"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:GetDownloadUrlForLayer",
    ]
    resources = [local.ecr_repository_arn]
  }
}

resource "aws_iam_role_policy" "instance_ecr_pull" {
  name   = "ecr-pull"
  role   = aws_iam_role.instance.id
  policy = data.aws_iam_policy_document.instance_ecr_pull.json
}
