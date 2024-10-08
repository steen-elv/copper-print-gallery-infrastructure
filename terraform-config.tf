# providers.tf
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 4.0"
    }
    heroku = {
      source  = "heroku/heroku"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

provider "heroku" {}

# variables.tf
variable "aws_region" {
  default = "us-west-2"
}

variable "project_name" {
  default = "copper-print-gallery"
}

variable "environment" {
  default = "production"
}

# main.tf

# Heroku Apps
resource "heroku_app" "web_app" {
  name   = "${var.project_name}-web"
  region = "us"
  stack  = "heroku-22"
}

resource "heroku_app" "artist_web_app" {
  name   = "${var.project_name}-artist"
  region = "us"
  stack  = "heroku-22"
}

# Heroku Add-ons
resource "heroku_addon" "auth0" {
  app_id = heroku_app.artist_web_app.id
  plan   = "auth0:free"
}

# AWS VPC
resource "aws_vpc" "main" {
  cidr_block = "10.0.0.0/16"

  tags = {
    Name = "${var.project_name}-vpc"
  }
}

data "aws_availability_zones" "available" {
  state = "available"
}

resource "aws_subnet" "main" {
  count             = 2
  vpc_id            = aws_vpc.main.id
  cidr_block        = "10.0.${count.index}.0/24"
  availability_zone = data.aws_availability_zones.available.names[count.index]

  tags = {
    Name = "${var.project_name}-subnet-${count.index + 1}"
  }
}

# AWS Lambda Functions
resource "aws_lambda_function" "content_service" {
  filename         = "content_service.zip"
  function_name    = "${var.project_name}-content-service"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  runtime          = "nodejs14.x"
  source_code_hash = filebase64sha256("content_service.zip")

  environment {
    variables = {
      DB_CONNECTION_STRING = aws_db_instance.main.endpoint
    }
  }
}

resource "aws_lambda_function" "search_service" {
  filename         = "search_service.zip"
  function_name    = "${var.project_name}-search-service"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  runtime          = "nodejs14.x"
  source_code_hash = filebase64sha256("search_service.zip")

  environment {
    variables = {
      DB_CONNECTION_STRING = aws_db_instance.main.endpoint
    }
  }
}

resource "aws_lambda_function" "image_service" {
  filename         = "image_service.zip"
  function_name    = "${var.project_name}-image-service"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "main.handler"
  runtime          = "python3.8"
  source_code_hash = filebase64sha256("image_service.zip")

  environment {
    variables = {
      S3_BUCKET = aws_s3_bucket.file_storage.id
    }
  }
}

# API Gateway
resource "aws_api_gateway_rest_api" "main" {
  name = "${var.project_name}-api"
}

resource "aws_api_gateway_resource" "content" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  parent_id   = aws_api_gateway_rest_api.main.root_resource_id
  path_part   = "content"
}

resource "aws_api_gateway_method" "content_post" {
  rest_api_id   = aws_api_gateway_rest_api.main.id
  resource_id   = aws_api_gateway_resource.content.id
  http_method   = "POST"
  authorization = "CUSTOM"
  authorizer_id = aws_api_gateway_authorizer.main.id
}

resource "aws_api_gateway_integration" "content_post" {
  rest_api_id = aws_api_gateway_rest_api.main.id
  resource_id = aws_api_gateway_resource.content.id
  http_method = aws_api_gateway_method.content_post.http_method

  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.content_service.invoke_arn
}

# API Gateway Authorizer
resource "aws_api_gateway_authorizer" "main" {
  name                             = "auth0-authorizer"
  rest_api_id                      = aws_api_gateway_rest_api.main.id
  authorizer_uri                   = aws_lambda_function.auth_middleware.invoke_arn
  authorizer_credentials           = aws_iam_role.invocation_role.arn
  authorizer_result_ttl_in_seconds = 300
  type                             = "TOKEN"
}

resource "aws_lambda_function" "auth_middleware" {
  filename         = "auth_middleware.zip"
  function_name    = "${var.project_name}-auth-middleware"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "index.handler"
  runtime          = "nodejs14.x"
  source_code_hash = filebase64sha256("auth_middleware.zip")

  environment {
    variables = {
      AUTH0_DOMAIN = heroku_addon.auth0.config_vars["AUTH0_DOMAIN"]
    }
  }
}

# RDS Instance
resource "aws_db_instance" "main" {
  identifier        = "${var.project_name}-db"
  allocated_storage = 20
  storage_type      = "gp2"
  engine            = "postgres"
  engine_version    = "13.3"
  instance_class    = "db.t3.micro"
  db_name           = "copperprintgallery"
  username          = "dbadmin"
  password          = "CHANGE_ME"  # Use AWS Secrets Manager in production

  vpc_security_group_ids = [aws_security_group.rds.id]
  db_subnet_group_name   = aws_db_subnet_group.main.name

  skip_final_snapshot = true
}

resource "aws_db_subnet_group" "main" {
  name       = "${var.project_name}-db-subnet-group"
  subnet_ids = aws_subnet.main[*].id
}

resource "aws_security_group" "rds" {
  name        = "${var.project_name}-rds-sg"
  description = "Security group for RDS instance"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 5432
    to_port     = 5432
    protocol    = "tcp"
    cidr_blocks = [aws_vpc.main.cidr_block]
  }
}

# S3 Buckets
resource "aws_s3_bucket" "file_storage" {
  bucket = "${var.project_name}-file-storage"
}

resource "aws_s3_bucket_acl" "file_storage" {
  bucket = aws_s3_bucket.file_storage.id
  acl    = "private"
}

resource "aws_s3_bucket_versioning" "file_storage" {
  bucket = aws_s3_bucket.file_storage.id
  versioning_configuration {
    status = "Enabled"
  }
}

# IAM Roles and Policies
resource "aws_iam_role" "lambda_exec" {
  name = "${var.project_name}-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_exec" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role" "invocation_role" {
  name = "${var.project_name}-api-gateway-auth-invocation"
  path = "/"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "apigateway.amazonaws.com"
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "invocation_policy" {
  name = "${var.project_name}-api-gateway-auth-invocation"
  role = aws_iam_role.invocation_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action   = "lambda:InvokeFunction"
        Effect   = "Allow"
        Resource = aws_lambda_function.auth_middleware.arn
      }
    ]
  })
}

# CloudWatch Log Groups
resource "aws_cloudwatch_log_group" "content_service" {
  name              = "/aws/lambda/${aws_lambda_function.content_service.function_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "search_service" {
  name              = "/aws/lambda/${aws_lambda_function.search_service.function_name}"
  retention_in_days = 14
}

resource "aws_cloudwatch_log_group" "image_service" {
  name              = "/aws/lambda/${aws_lambda_function.image_service.function_name}"
  retention_in_days = 14
}

# Route 53 DNS Configuration
resource "aws_route53_zone" "main" {
  name = "copperprintgallery.com"
}

resource "aws_route53_record" "www" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "www.copperprintgallery.com"
  type    = "CNAME"
  ttl     = "300"
  records = [heroku_app.web_app.heroku_hostname]
}

resource "aws_route53_record" "artist" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "artist.copperprintgallery.com"
  type    = "CNAME"
  ttl     = "300"
  records = [heroku_app.artist_web_app.heroku_hostname]
}

resource "aws_route53_record" "api" {
  zone_id = aws_route53_zone.main.zone_id
  name    = "api.copperprintgallery.com"
  type    = "A"

  alias {
    name                   = aws_api_gateway_domain_name.main.cloudfront_domain_name
    zone_id                = aws_api_gateway_domain_name.main.cloudfront_zone_id
    evaluate_target_health = true
  }
}

resource "aws_api_gateway_domain_name" "main" {
  domain_name              = "api.copperprintgallery.com"
  regional_certificate_arn = aws_acm_certificate.api.arn

  endpoint_configuration {
    types = ["REGIONAL"]
  }
}

resource "aws_acm_certificate" "api" {
  domain_name       = "api.copperprintgallery.com"
  validation_method = "DNS"
}

# API Gateway Deployment
resource "aws_api_gateway_deployment" "main" {
  depends_on = [
    aws_api_gateway_integration.content_post,
  ]

  rest_api_id = aws_api_gateway_rest_api.main.id
  stage_name  = "prod"
}

# outputs.tf
output "web_app_url" {
  value = "https://${heroku_app.web_app.name}.herokuapp.com"
}

output "artist_web_app_url" {
  value = "https://${heroku_app.artist_web_app.name}.herokuapp.com"
}

output "api_url" {
  value = aws_api_gateway_deployment.main.invoke_url
}

output "database_endpoint" {
  value = aws_db_instance.main.endpoint
}