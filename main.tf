# Local variables
locals {
  common_tags = {
    Agency      = var.agency
    Project     = var.team_app_name
    Environment = var.environment
    ManagedBy   = "Terraform"
  }
}

# Configure providers
provider "aws" {
  region = var.aws_region
}

# Create a random string for bucket suffix
resource "random_string" "bucket_uid" {
  length  = 4
  upper   = false
  numeric = false
  special = false
}

# ------------------------------------------------------------------------------
# S3 — Artifact Store
# ------------------------------------------------------------------------------
resource "aws_s3_bucket" "artifacts" {
  #bucket = "${var.agency}-${var.team_app_name}-${var.environment}-${var.scope}-bucket-${random_string.bucket_uid.result}"
  #bucket = "${var.team_app_name}-artifacts-${data.aws_caller_identity.current.account_id}"
  bucket = "${var.agency}-${var.team_app_name}-${var.environment}-artifacts-bucket-${random_string.bucket_uid.result}"
  force_destroy = true

  tags = local.common_tags
}

resource "aws_s3_bucket_versioning" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  versioning_configuration {
    status = "Enabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  bucket = aws_s3_bucket.artifacts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  bucket                  = aws_s3_bucket.artifacts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# # ------------------------------------------------------------------------------
# # CodeStar Connection (GitHub / Bitbucket / GitLab)
# # After apply, activate the connection manually in the AWS Console once.
# # ------------------------------------------------------------------------------
# resource "aws_codestarconnections_connection" "source" {
#   name          = "${var.team_app_name}-connection"
#   provider_type = var.source_provider

#   tags = local.common_tags
# }

# ------------------------------------------------------------------------------
# Lambda — Deployment Target
# ------------------------------------------------------------------------------
resource "aws_lambda_function" "app" {
  function_name = "${var.team_app_name}-function"
  role          = aws_iam_role.lambda_exec.arn
  runtime       = var.lambda_runtime
  handler       = var.lambda_handler
  timeout       = 30
  memory_size   = 128

  # Placeholder ZIP so Terraform can create the function on first apply.
  # CodePipeline will overwrite it on every successful deploy.
  filename      = data.archive_file.lambda_placeholder.output_path
  source_code_hash = data.archive_file.lambda_placeholder.output_base64sha256

  environment {
    variables = {
      ENVIRONMENT = var.environment
    }
  }

  tags = local.common_tags
}

resource "aws_lambda_alias" "live" {
  name             = "live"
  function_name    = aws_lambda_function.app.function_name
  function_version = "$LATEST"
}

# ------------------------------------------------------------------------------
# CodeBuild — Build Stage
# ------------------------------------------------------------------------------
resource "aws_codebuild_project" "build" {
  name          = "${var.team_app_name}-build"
  description   = "Compile and package application artifacts"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "ENVIRONMENT"
      value = var.environment
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-build.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild_build.name
      stream_name = "build"
    }
  }

  tags = local.common_tags
}

# ------------------------------------------------------------------------------
# CodeBuild — Test Stage
# ------------------------------------------------------------------------------
resource "aws_codebuild_project" "test" {
  name          = "${var.team_app_name}-test"
  description   = "Run unit and integration tests"
  service_role  = aws_iam_role.codebuild.arn
  build_timeout = 20

  artifacts {
    type = "CODEPIPELINE"
  }

  environment {
    compute_type                = "BUILD_GENERAL1_SMALL"
    image                       = "aws/codebuild/standard:7.0"
    type                        = "LINUX_CONTAINER"
    image_pull_credentials_type = "CODEBUILD"

    environment_variable {
      name  = "ENVIRONMENT"
      value = var.environment
    }
  }

  source {
    type      = "CODEPIPELINE"
    buildspec = "buildspec/buildspec-test.yml"
  }

  logs_config {
    cloudwatch_logs {
      group_name  = aws_cloudwatch_log_group.codebuild_test.name
      stream_name = "test"
    }
  }

  tags = local.common_tags
}

# ------------------------------------------------------------------------------
# CodePipeline
# ------------------------------------------------------------------------------
resource "aws_codepipeline" "main" {
  name     = "${var.team_app_name}-pipeline"
  role_arn = aws_iam_role.codepipeline.arn

  artifact_store {
    location = aws_s3_bucket.artifacts.bucket
    type     = "S3"
  }

  # Stage 1: Source
  stage {
    name = "Source"

    action {
      name             = "Source"
      category         = "Source"
      owner            = "AWS"
      provider         = "CodeStarSourceConnection"
      version          = "1"
      output_artifacts = ["source_output"]

      configuration = {
        ConnectionArn        = var.source_codeconnections_arn
        FullRepositoryId     = "${var.repo_org}/${var.repo_name}"
        BranchName           = var.repo_branch
        OutputArtifactFormat = "CODE_ZIP"
        DetectChanges        = "true"
      }
    }
  }

  # Stage 2: Build
  stage {
    name = "Build"

    action {
      name             = "Build"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["source_output"]
      output_artifacts = ["build_output"]

      configuration = {
        ProjectName = aws_codebuild_project.build.name
      }
    }
  }

  # Stage 3: Test
  stage {
    name = "Test"

    action {
      name             = "Test"
      category         = "Build"
      owner            = "AWS"
      provider         = "CodeBuild"
      version          = "1"
      input_artifacts  = ["build_output"]
      output_artifacts = ["test_output"]

      configuration = {
        ProjectName = aws_codebuild_project.test.name
      }
    }
  }

  # Stage 4: Deploy → Lambda
  stage {
    name = "Deploy"

    action {
      name            = "DeployToLambda"
      category        = "Deploy"
      owner           = "AWS"
      provider        = "Lambda"
      version         = "1"
      input_artifacts = ["test_output"]

      configuration = {
        FunctionName = aws_lambda_function.app.function_name
        #UserParameters = jsonencode({
          #alias = aws_lambda_alias.live.name
        #})
      }
    }
  }

  tags = local.common_tags

  depends_on = [
    aws_iam_role_policy_attachment.codepipeline_policy
  ]
}

# ------------------------------------------------------------------------------
# CloudWatch Log Groups
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "codebuild_build" {
  name              = "/aws/codebuild/${var.team_app_name}-build"
  retention_in_days = 7
  tags              = local.common_tags
}

resource "aws_cloudwatch_log_group" "codebuild_test" {
  name              = "/aws/codebuild/${var.team_app_name}-test"
  retention_in_days = 7
  tags              = local.common_tags
}

# ------------------------------------------------------------------------------
# Data Sources
# ------------------------------------------------------------------------------
data "aws_caller_identity" "current" {}
data "aws_partition" "current" {}

data "archive_file" "lambda_placeholder" {
  type        = "zip"
  output_path = "${path.module}/placeholder.zip"

  source {
    content  = "exports.handler = async () => ({ statusCode: 200, body: 'placeholder' });"
    filename = "index.js"
  }
}

# ------------------------------------------------------------------------------
# IAM
# ------------------------------------------------------------------------------

# CodePipeline Role

resource "aws_iam_role" "codepipeline" {
  name               = "${var.team_app_name}-codepipeline-role"
  assume_role_policy = data.aws_iam_policy_document.codepipeline_assume.json
  tags               = local.common_tags
}

resource "aws_iam_policy" "codepipeline" {
  name   = "${var.team_app_name}-codepipeline-policy"
  policy = data.aws_iam_policy_document.codepipeline_permissions.json
  tags   = local.common_tags
}

data "aws_iam_policy_document" "codepipeline_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codepipeline.amazonaws.com"]
    }
  }
}

data "aws_iam_policy_document" "codepipeline_permissions" {
  # S3 artifact store
  statement {
    sid    = "S3ArtifactStore"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:GetBucketVersioning",
      "s3:GetObjectVersion",
      "s3:ListBucket",
    ]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }

  # Codeconnection (source)
  statement {
    sid       = "Codeconnection"
    effect    = "Allow"
    actions   = ["codestar-connections:UseConnection"]
    resources = [var.source_codeconnections_arn]
  }

  # CodeBuild (trigger builds & tests)
  statement {
    sid    = "CodeBuild"
    effect = "Allow"
    actions = [
      "codebuild:BatchGetBuilds",
      "codebuild:StartBuild",
      "codebuild:StopBuild",
    ]
    resources = [
      aws_codebuild_project.build.arn,
      aws_codebuild_project.test.arn,
    ]
  }

  # Lambda (deploy stage)
  statement {
    sid    = "LambdaDeploy"
    effect = "Allow"
    actions = [
      "lambda:InvokeFunction",
      "lambda:UpdateFunctionCode",
      "lambda:GetFunction",
      "lambda:PublishVersion",
      "lambda:UpdateAlias",
      "lambda:GetAlias",
    ]
    resources = [
      aws_lambda_function.app.arn,
      "${aws_lambda_function.app.arn}:*",
    ]
  }

  # IAM PassRole (allow pipeline to pass roles to downstream services)
  statement {
    sid     = "PassRole"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [
      aws_iam_role.codebuild.arn,
      aws_iam_role.lambda_exec.arn,
    ]
  }
}

resource "aws_iam_role_policy_attachment" "codepipeline_policy" {
  role       = aws_iam_role.codepipeline.name
  policy_arn = aws_iam_policy.codepipeline.arn
}

# CodeBuild Role

resource "aws_iam_role" "codebuild" {
  name               = "${var.team_app_name}-codebuild-role"
  assume_role_policy = data.aws_iam_policy_document.codebuild_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "codebuild_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codebuild.amazonaws.com"]
    }
  }
}

resource "aws_iam_policy" "codebuild" {
  name   = "${var.team_app_name}-codebuild-policy"
  policy = data.aws_iam_policy_document.codebuild_permissions.json
  tags   = local.common_tags
}

resource "aws_iam_role_policy_attachment" "codebuild_policy" {
  role       = aws_iam_role.codebuild.name
  policy_arn = aws_iam_policy.codebuild.arn
}

data "aws_iam_policy_document" "codebuild_permissions" {
  # S3 artifact store
  statement {
    sid    = "S3Artifacts"
    effect = "Allow"
    actions = [
      "s3:GetObject",
      "s3:PutObject",
      "s3:GetBucketVersioning",
      "s3:GetObjectVersion",
    ]
    resources = [
      aws_s3_bucket.artifacts.arn,
      "${aws_s3_bucket.artifacts.arn}/*",
    ]
  }

  # CloudWatch Logs
  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
    ]
    resources = [
      "${aws_cloudwatch_log_group.codebuild_build.arn}:*",
      "${aws_cloudwatch_log_group.codebuild_test.arn}:*",
    ]
  }

  # CodeBuild report groups (for test reports)
  statement {
    sid    = "CodeBuildReports"
    effect = "Allow"
    actions = [
      "codebuild:CreateReportGroup",
      "codebuild:CreateReport",
      "codebuild:UpdateReport",
      "codebuild:BatchPutTestCases",
      "codebuild:BatchPutCodeCoverages",
    ]
    resources = [
      "arn:${data.aws_partition.current.partition}:codebuild:${var.aws_region}:${data.aws_caller_identity.current.account_id}:report-group/${var.team_app_name}-*"
    ]
  }
}

# Lambda Execution Role

resource "aws_iam_role" "lambda_exec" {
  name               = "${var.team_app_name}-lambda-exec-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume.json
  tags               = local.common_tags
}

data "aws_iam_policy_document" "lambda_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:${data.aws_partition.current.partition}:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}
