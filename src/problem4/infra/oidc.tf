# AWS verifies GitHub's JWKS endpoint against its own trusted CA library and falls
# back to the thumbprint list only when that fails, so the list is read from the
# live certificate chain rather than hardcoded.
data "tls_certificate" "github" {
  url = "https://${local.github_oidc_host}/.well-known/openid-configuration"
}

resource "aws_iam_openid_connect_provider" "github" {
  url             = "https://${local.github_oidc_host}"
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = data.tls_certificate.github.certificates[*].sha1_fingerprint
}
