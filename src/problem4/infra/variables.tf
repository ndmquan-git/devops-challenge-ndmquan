variable "github_owner" {
  description = "GitHub user or organisation that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name without the owner."
  type        = string
}

variable "github_owner_id" {
  description = "Numeric owner ID when the repository emits immutable subject claims (created after 2026-07-15 or opted in); null for the name-only format."
  type        = number
  default     = null

  validation {
    condition     = (var.github_owner_id == null) == (var.github_repo_id == null)
    error_message = "Set github_owner_id and github_repo_id together, or leave both null."
  }
}

variable "github_repo_id" {
  description = "Numeric repository ID paired with github_owner_id; null for the name-only format."
  type        = number
  default     = null
}

variable "aws_region" {
  description = "Region that holds the ECR repository and the deploy targets."
  type        = string
}

variable "app_tag" {
  description = "Value of the App tag on the EC2 instances the deploy role may send commands to."
  type        = string
  default     = "p4-backend"
}

variable "ecr_repository_name" {
  description = "ECR repository the publish role pushes to and the instances pull from."
  type        = string
  default     = "p4-backend"
}

variable "environments" {
  description = "Deploy targets keyed by GitHub environment name; the key is also the Env tag the deploy role requires on instances."
  type = map(object({
    target_group_arn           = string
    frontend_bucket            = string
    cloudfront_distribution_id = string
  }))

  validation {
    condition     = alltrue([for e in values(var.environments) : can(regex("^arn:aws[a-z-]*:elasticloadbalancing:", e.target_group_arn))])
    error_message = "Each target_group_arn must be a full Elastic Load Balancing target group ARN."
  }
}

variable "create_ecr_repository" {
  description = "Create the ECR repository (immutable tags, scan on push); set false when it already exists or lives in another account."
  type        = bool
  default     = true
}

variable "ecr_account_id" {
  description = "Account that holds the ECR repository and the publish role, when that is another account; the instance role then pulls across accounts. Null when this account holds them."
  type        = string
  default     = null

  validation {
    condition     = var.ecr_account_id == null || (can(regex("^[0-9]{12}$", var.ecr_account_id)) && !var.create_ecr_repository)
    error_message = "ecr_account_id must be a 12-digit account ID, with create_ecr_repository = false."
  }
}

variable "ecr_pull_account_ids" {
  description = "Other accounts whose <app_tag>-instance role may pull from the repository; applies in the account that holds it."
  type        = list(string)
  default     = []

  validation {
    condition     = alltrue([for id in var.ecr_pull_account_ids : can(regex("^[0-9]{12}$", id))]) && (length(var.ecr_pull_account_ids) == 0 || var.ecr_account_id == null)
    error_message = "ecr_pull_account_ids takes 12-digit account IDs, and only where ecr_account_id is null."
  }
}
