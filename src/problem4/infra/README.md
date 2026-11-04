# IAM for the Problem 4 pipelines

Terraform root module for the AWS identity side of the two pipelines in [`SOLUTION.md`](../SOLUTION.md): the GitHub OIDC provider, a role that pushes images, one deploy role per environment, and the instance profile of the EC2 hosts. The ALB, instances, bucket and distribution are inputs, not resources.

| Resource | Name | Trusted by | May do |
|---|---|---|---|
| OIDC provider | `token.actions.githubusercontent.com` | GitHub Actions | Issue `AssumeRoleWithWebIdentity` for the roles below |
| Publish role (the account that holds the repository) | `<repo>-github-publish` | `main` branch running [`_container.yml`](../.github/workflows/_container.yml) | Log in to ECR; push to the one repository |
| Deploy role, per environment | `<repo>-github-deploy-<env>` | GitHub environment `<env>` running [`_deploy-ec2.yml`](../.github/workflows/_deploy-ec2.yml) or [`_deploy-s3.yml`](../.github/workflows/_deploy-s3.yml) | Drain and re-register the environment's target group; run `AWS-RunShellScript` on instances tagged `App=<app_tag>`, `Env=<env>`; upload to and read back from the frontend bucket; invalidate the distribution. Explicit deny on `iam:*`, `sts:AssumeRole`, `ec2:TerminateInstances` |
| Instance role and profile | `<app_tag>-instance` | EC2 | `AmazonSSMManagedInstanceCore`; pull from the one repository, in this account or the one `ecr_account_id` names |
| ECR repository (optional, `create_ecr_repository`) | `<ecr_repository_name>` | | Immutable tags, scan on push, encrypted with the key below |
| KMS key for the repository (with the repository) | `alias/ecr-<ecr_repository_name>` | ECR, through the grants it creates on the key | Encrypt on push and decrypt on pull; yearly rotation. Pullers in other accounts need no KMS permission |
| ECR repository policy (when `ecr_pull_account_ids` is set) | | The `<app_tag>-instance` role of each listed account | Pull from the repository |

One deploy role per environment, shared by both deploy workflows, because the workflows read a single `AWS_DEPLOY_ROLE_ARN` variable per environment and the GitHub environment (required reviewers, `main` only) is the promotion boundary. The trust policy still names both workflow files, so only a job running one of them from `main` can assume the role, and both files hardcode the script that runs with it. Splitting into an EC2 role and an S3 role would need a second variable name in the workflows.

## Apply

Requires Terraform 1.9 or newer and credentials for the target AWS account. Staging and production in separate accounts means one apply per account, with `environments` holding only the environments that live in that account. One account holds the ECR repository and the publish role; the production account is the better holder, so that production never pulls from the staging account. Its apply lists the other account in `ecr_pull_account_ids`; the other account's apply sets `ecr_account_id` to the holder and `create_ecr_repository = false`. The repository policy admits the other account's instance role by name, so both accounts keep the same `app_tag`.

```bash
cd src/problem4/infra
cp terraform.tfvars.example terraform.tfvars   # then replace every placeholder
terraform init
terraform plan
terraform apply
```

Then, once, make the repository emit the `sub` claim the trust policies expect (see [Subject claim](#subject-claim)):

```bash
gh api --method PUT "repos/<owner>/<repo>/actions/oidc/customization/sub" \
  --input - <<'EOF'
{"use_default": false, "include_claim_keys": ["repo", "context", "job_workflow_ref"]}
EOF
```

Finally set the GitHub variables listed below, the ECR ones before `AWS_DEPLOY_ROLE_ARN` because the instances pull only from ECR, and attach the instance profile to the backend instances. Until the variables are set the deploy jobs run as dry runs; until the subject claim is customised, `AssumeRoleWithWebIdentity` is denied, so a mismatch fails closed.

## Outputs to GitHub variables

| Output or input | GitHub variable | Scope |
|---|---|---|
| `publish_role_arn` (from the account that holds the repository) | `AWS_ECR_ROLE_ARN` | Repository |
| `ecr_registry` (the same in every account) | `ECR_REGISTRY` | Repository |
| input `aws_region` | `AWS_REGION` | Repository |
| `deploy_role_arns["<env>"]` | `AWS_DEPLOY_ROLE_ARN` | Environment `<env>` |
| input `environments.<env>.target_group_arn` | `TARGET_GROUP_ARN` | Environment `<env>` |
| input `environments.<env>.frontend_bucket` | `FRONTEND_BUCKET` | Environment `<env>` |
| input `environments.<env>.cloudfront_distribution_id` | `CLOUDFRONT_DISTRIBUTION_ID` | Environment `<env>` |
| `instance_profile_name` | none; attach to the EC2 launch template | |

`BACKEND_URL` and `FRONTEND_URL` come from the ALB and CloudFront, not from this module. The full variable list is in [Connecting a real AWS account](../SOLUTION.md#connecting-a-real-aws-account).

## Subject claim

IAM evaluates only the `aud`, `sub`, `amr`, `azp`, `email` and `oaud` claims of an OIDC token ([IAM condition keys for OIDC federation](https://docs.aws.amazon.com/IAM/latest/UserGuide/reference_policies_iam-condition-keys.html#condition-keys-wif)), so `job_workflow_ref` cannot be a condition key of its own. GitHub instead lets a repository fold extra claims into `sub` ([customizing the subject claim](https://docs.github.com/en/actions/reference/security/oidc#customizing-the-subject-claims-for-an-organization-or-repository)). With `include_claim_keys` set to `repo`, `context`, `job_workflow_ref`, the trust policies match exactly:

| Role | `token.actions.githubusercontent.com:sub` |
|---|---|
| Publish | `repo:<repo segment>:ref:refs/heads/main:job_workflow_ref:<owner>/<repo>/.github/workflows/_container.yml@refs/heads/main` |
| Deploy `<env>` | `repo:<repo segment>:environment:<env>:job_workflow_ref:<owner>/<repo>/.github/workflows/_deploy-ec2.yml@refs/heads/main`, or the same with `_deploy-s3.yml` |

`<repo segment>` is `<owner>/<repo>` for a repository created before 2026-07-15, and `<owner>@<owner_id>/<repo>@<repo_id>` for one created later or opted in to immutable subject claims; set `github_owner_id` and `github_repo_id` for the second form. `gh api repos/<owner>/<repo>/actions/oidc/customization/sub` shows the prefix the repository emits, and the `oidc_subjects` output shows what the roles expect. `aud` is `sts.amazonaws.com`, the value `aws-actions/configure-aws-credentials` requests.

## Permission notes

- **Wildcard resources are limited to actions without resource-level support**: `ec2:DescribeInstances`, `elasticloadbalancing:DescribeTargetHealth`, `ssm:GetCommandInvocation` and `ecr:GetAuthorizationToken` accept only `*` (AWS Service Reference, `Resources` of each action). `DescribeTargetHealth` is what the `target-deregistered` and `target-in-service` waiters call.
- **`ssm:SendCommand` is two statements**: the `AWS-RunShellScript` document ARN without a condition, and the instance ARN with `ssm:resourceTag/App` and `ssm:resourceTag/Env`, as in the AWS example for [restricting Run Command access based on tags](https://docs.aws.amazon.com/systems-manager/latest/userguide/run-command-setting-up.html#tag-based-access). A command to an instance missing either tag is denied.
- **The deploy role has no ECR permission**: the instances pull through the instance profile.
- **Object reads on the bucket** (`s3:GetObject`, `s3:GetObjectVersion`, `s3:ListBucketVersions`) exist so a rollback can restore a previous `index.html` version.
- **Cross-account pulls** need both sides: the other account's instance role allows the pull on the holder's repository ARN, and the holder's repository policy names that role through `aws:PrincipalArn` on the account principal, which does not require the role to exist when the policy is applied.

## Checks

```bash
terraform fmt -check -recursive && terraform init -backend=false && terraform validate
trivy config --severity HIGH,CRITICAL --exit-code 1 .
tflint
```
