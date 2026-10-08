terraform {
  required_version = ">= 1.5"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Used to make the bucket name globally unique (S3 names are shared by all AWS accounts).
data "aws_caller_identity" "current" {}

# ---------- Step 1: ingestion bucket ----------

resource "aws_s3_bucket" "ingestion" {
  bucket = "${var.project}-ingestion-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "ingestion" {
  bucket = aws_s3_bucket.ingestion.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------- Step 2: distribution bucket ----------

resource "aws_s3_bucket" "distribution" {
  bucket = "${var.project}-distribution-${data.aws_caller_identity.current.account_id}"
}

resource "aws_s3_bucket_public_access_block" "distribution" {
  bucket = aws_s3_bucket.distribution.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ---------- Step 3: DynamoDB table ----------

resource "aws_dynamodb_table" "items" {
  name         = "${var.project}-items"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  # Only key attributes are declared; every other column is schema-less.
  attribute {
    name = "id"
    type = "S"
  }
}

# ---------- Step 4: publish-file Lambda ----------

# Zips the handler folder. Terraform uses this only for the first create.
data "archive_file" "publish_file" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/publish_file"
  output_path = "${path.module}/build/publish_file.zip"
}

# Trust policy: WHO may use the role (the Lambda service).
data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "publish_file" {
  name               = "${var.project}-publish-file-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

# Lets the function write logs to CloudWatch.
resource "aws_iam_role_policy_attachment" "publish_file_logs" {
  role       = aws_iam_role.publish_file.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Permissions: WHAT the role may do (least privilege, scoped to our resources).
data "aws_iam_policy_document" "publish_file" {
  statement {
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.ingestion.arn}/*"]
  }

  statement {
    actions   = ["s3:PutObject"]
    resources = ["${aws_s3_bucket.distribution.arn}/*"]
  }

  statement {
    actions   = ["dynamodb:PutItem", "dynamodb:BatchWriteItem"]
    resources = [aws_dynamodb_table.items.arn]
  }
}

resource "aws_iam_role_policy" "publish_file" {
  name   = "publish-file-access"
  role   = aws_iam_role.publish_file.id
  policy = data.aws_iam_policy_document.publish_file.json
}

resource "aws_cloudwatch_log_group" "publish_file" {
  name              = "/aws/lambda/publish-file"
  retention_in_days = 14
}

# No function URL and no API Gateway permission: internal, console-invoke only.
resource "aws_lambda_function" "publish_file" {
  function_name = "publish-file"
  role          = aws_iam_role.publish_file.arn
  runtime       = "python3.12"
  handler       = "handler.lambda_handler"
  timeout       = 60
  memory_size   = 256

  filename         = data.archive_file.publish_file.output_path
  source_code_hash = data.archive_file.publish_file.output_base64sha256

  environment {
    variables = {
      TABLE_NAME          = aws_dynamodb_table.items.name
      INGESTION_BUCKET    = aws_s3_bucket.ingestion.bucket
      DISTRIBUTION_BUCKET = aws_s3_bucket.distribution.bucket
    }
  }

  # GitHub Actions deploys new code, so Terraform must not revert it.
  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }

  # Create the log group first so the function doesn't make an unmanaged one.
  depends_on = [aws_cloudwatch_log_group.publish_file]
}

# ---------- Step 5: get-item Lambda ----------

data "archive_file" "get_item" {
  type        = "zip"
  source_dir  = "${path.module}/../lambdas/get_item"
  output_path = "${path.module}/build/get_item.zip"
}

# Reuses the same trust policy as publish-file (Lambda service may assume the role).
resource "aws_iam_role" "get_item" {
  name               = "${var.project}-get-item-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

resource "aws_iam_role_policy_attachment" "get_item_logs" {
  role       = aws_iam_role.get_item.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Read-only: this function can only fetch single items from our table.
data "aws_iam_policy_document" "get_item" {
  statement {
    actions   = ["dynamodb:GetItem"]
    resources = [aws_dynamodb_table.items.arn]
  }
}

resource "aws_iam_role_policy" "get_item" {
  name   = "get-item-access"
  role   = aws_iam_role.get_item.id
  policy = data.aws_iam_policy_document.get_item.json
}

resource "aws_cloudwatch_log_group" "get_item" {
  name              = "/aws/lambda/get-item"
  retention_in_days = 14
}

resource "aws_lambda_function" "get_item" {
  function_name = "get-item"
  role          = aws_iam_role.get_item.arn
  runtime       = "python3.12"
  handler       = "handler.lambda_handler"

  filename         = data.archive_file.get_item.output_path
  source_code_hash = data.archive_file.get_item.output_base64sha256

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.items.name
    }
  }

  # GitHub Actions deploys new code, so Terraform must not revert it.
  lifecycle {
    ignore_changes = [filename, source_code_hash]
  }

  depends_on = [aws_cloudwatch_log_group.get_item]
}

# ---------- Step 6: API Gateway (HTTP API) ----------

resource "aws_apigatewayv2_api" "main" {
  name          = "${var.project}-api"
  protocol_type = "HTTP"
}

# How API Gateway calls the Lambda. AWS_PROXY passes the whole request through.
resource "aws_apigatewayv2_integration" "get_item" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.get_item.invoke_arn
  payload_format_version = "2.0"
}

# Which requests go to that integration. {id} becomes pathParameters.id.
resource "aws_apigatewayv2_route" "get_item" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /items/{id}"
  target    = "integrations/${aws_apigatewayv2_integration.get_item.id}"
}

# Second route on the same Lambda: the handler picks the code path from the route key.
resource "aws_apigatewayv2_route" "validation" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /validation"
  target    = "integrations/${aws_apigatewayv2_integration.get_item.id}"
}

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true
}

# Lets API Gateway invoke get-item. publish-file has no such permission, so it stays internal.
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowApiGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_item.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
