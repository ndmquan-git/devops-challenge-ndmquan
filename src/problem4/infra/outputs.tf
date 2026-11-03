output "publish_role_arn" {
  description = "Role the container workflow assumes to push images; GitHub repository variable AWS_ECR_ROLE_ARN."
  value       = aws_iam_role.publish.arn
}

output "deploy_role_arns" {
  description = "Deploy role ARN per environment; GitHub environment variable AWS_DEPLOY_ROLE_ARN."
  value       = { for env, role in aws_iam_role.deploy : env => role.arn }
}

output "ecr_registry" {
  description = "Registry host for image references; GitHub repository variable ECR_REGISTRY."
  value       = local.ecr_registry
}

output "instance_profile_name" {
  description = "Instance profile to attach to the backend EC2 instances."
  value       = aws_iam_instance_profile.instance.name
}

output "oidc_subjects" {
  description = "Exact sub claim values each role trusts, to compare with the repository's OIDC subject settings."
  value       = merge({ publish = [local.publish_subject] }, local.deploy_subjects)
}
