provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      App       = var.app_tag
      ManagedBy = "terraform"
    }
  }
}

data "aws_caller_identity" "current" {}

data "aws_partition" "current" {}

locals {
  account_id = data.aws_caller_identity.current.account_id
  partition  = data.aws_partition.current.partition

  github_branch    = "main"
  github_oidc_host = "token.actions.githubusercontent.com"

  # Repositories created after 2026-07-15 (or opted in) emit "owner@id/repo@id"
  # in the sub claim's repo segment instead of "owner/repo".
  repo_segment = var.github_owner_id == null ? "${var.github_owner}/${var.github_repo}" : "${var.github_owner}@${var.github_owner_id}/${var.github_repo}@${var.github_repo_id}"

  workflow_ref = {
    for f in ["_container.yml", "_deploy-ec2.yml", "_deploy-s3.yml"] :
    f => "${var.github_owner}/${var.github_repo}/.github/workflows/${f}@refs/heads/${local.github_branch}"
  }

  # IAM evaluates only aud, sub, amr, azp, email and oaud from an OIDC token, so the
  # reusable workflow is pinned through GitHub's customised sub format
  # "repo:<repo>:<context>:job_workflow_ref:<ref>", not through a job_workflow_ref key.
  publish_subject = "repo:${local.repo_segment}:ref:refs/heads/${local.github_branch}:job_workflow_ref:${local.workflow_ref["_container.yml"]}"

  deploy_subjects = {
    for env in keys(var.environments) : env => [
      for f in ["_deploy-ec2.yml", "_deploy-s3.yml"] :
      "repo:${local.repo_segment}:environment:${env}:job_workflow_ref:${local.workflow_ref[f]}"
    ]
  }

  # The account that holds the repository also holds the publish role; another
  # account's instances pull from it through the repository policy in ecr.tf.
  holds_ecr          = var.ecr_account_id == null
  ecr_account_id     = coalesce(var.ecr_account_id, local.account_id)
  ecr_repository_arn = "arn:${local.partition}:ecr:${var.aws_region}:${local.ecr_account_id}:repository/${var.ecr_repository_name}"
  ecr_registry       = "${local.ecr_account_id}.dkr.ecr.${var.aws_region}.${data.aws_partition.current.dns_suffix}"
}
