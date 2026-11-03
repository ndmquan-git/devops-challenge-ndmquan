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
