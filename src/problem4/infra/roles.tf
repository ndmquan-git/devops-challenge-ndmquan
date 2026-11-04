data "aws_iam_policy_document" "publish_trust" {
  count = local.holds_ecr ? 1 : 0

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = [local.publish_subject]
    }
  }
}

resource "aws_iam_role" "publish" {
  count = local.holds_ecr ? 1 : 0

  name                 = "${var.github_repo}-github-publish"
  description          = "GitHub Actions: push ${var.ecr_repository_name} images from ${local.github_branch}"
  assume_role_policy   = data.aws_iam_policy_document.publish_trust[0].json
  max_session_duration = 3600
}

data "aws_iam_policy_document" "deploy_trust" {
  for_each = var.environments

  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]

    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:aud"
      values   = ["sts.amazonaws.com"]
    }

    condition {
      test     = "StringEquals"
      variable = "${local.github_oidc_host}:sub"
      values   = local.deploy_subjects[each.key]
    }
  }
}

resource "aws_iam_role" "deploy" {
  for_each = var.environments

  name                 = "${var.github_repo}-github-deploy-${each.key}"
  description          = "GitHub Actions: deploy the ${each.key} environment"
  assume_role_policy   = data.aws_iam_policy_document.deploy_trust[each.key].json
  max_session_duration = 3600

  tags = {
    Env = each.key
  }
}

data "aws_iam_policy_document" "instance_trust" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.${data.aws_partition.current.dns_suffix}"]
    }
  }
}

resource "aws_iam_role" "instance" {
  name               = "${var.app_tag}-instance"
  description        = "EC2 hosts of ${var.app_tag}: SSM agent and ECR pull"
  assume_role_policy = data.aws_iam_policy_document.instance_trust.json
}

resource "aws_iam_role_policy_attachment" "instance_ssm" {
  role       = aws_iam_role.instance.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "instance" {
  name = aws_iam_role.instance.name
  role = aws_iam_role.instance.name
}
