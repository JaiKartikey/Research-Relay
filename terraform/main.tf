# All AWS infrastructure for Research-Relay EC2 (the cheap start/stop version), in one file.
#
#   cd terraform
#   ./tf.sh apply      (tf.sh = terraform + the CloudShell setup and init, see the README)
#
# What it makes:
# - 1 small VPC with 1 public subnet
# - 1 EC2 instance (t4g.small) that runs everything with Docker Compose:
#   app (+ worker), TensorZero, Redis, Postgres (data lives on the EC2 disk)
# - 1 security group: only port 80 (the app) is open. No SSH port.
# - 1 IAM role for the instance (no access keys anywhere)
# - Bedrock guardrail + Secrets Manager secret (same as the ECS version)
# - 1 S3 bucket that holds a zip of this code; the instance downloads it on every boot

terraform {
  required_version = ">= 1.10"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0, < 7.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6, < 4.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4, < 3.0"
    }
  }

  # Same state bucket as the ECS version (made by bootstrap.sh), but a different file inside it.
  backend "s3" {
    key          = "research-relay-ec2/terraform.tfstate"
    region       = "ap-southeast-2"
    encrypt      = true
    use_lockfile = true
  }
}

provider "aws" {
  region = var.aws_region
}

# ─── Variables ────────────────────────────────────────────────────────────────

variable "aws_region" {
  type    = string
  default = "ap-southeast-2" # Sydney
}

variable "instance_type" {
  description = "t4g.small = 2 vCPU, 2 GB RAM, ARM (Graviton). Cheapest size that fits the embedding model."
  type        = string
  default     = "t4g.small"
}

variable "allowed_cidr" {
  description = "Who can open the app. 0.0.0.0/0 = everyone (the API key still protects it). Use \"YOUR_IP/32\" to allow only you."
  type        = string
  default     = "0.0.0.0/0"
}

locals {
  name = "research-relay-ec2"
}

data "aws_caller_identity" "current" {}

data "aws_availability_zones" "available" {
  state = "available"
}

# Latest Amazon Linux 2023 for ARM. AWS keeps this parameter up to date.
data "aws_ssm_parameter" "al2023_arm" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-arm64"
}

# ─── Network: 1 VPC, 1 public subnet ──────────────────────────────────────────

resource "aws_vpc" "main" {
  cidr_block           = "10.1.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.name}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
}

resource "aws_subnet" "public" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = "10.1.0.0/24"
  availability_zone       = data.aws_availability_zones.available.names[0]
  map_public_ip_on_launch = true # new public IP on every Start (not charged while stopped)
  tags                    = { Name = "${local.name}-public" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
}

resource "aws_route_table_association" "public" {
  subnet_id      = aws_subnet.public.id
  route_table_id = aws_route_table.public.id
}

# ─── Security group: only the app port is open ────────────────────────────────

resource "aws_security_group" "app" {
  name   = "${local.name}-app"
  vpc_id = aws_vpc.main.id

  # Internet -> app (port 80 on the instance = port 8000 in the app container)
  ingress {
    from_port   = 80
    to_port     = 80
    protocol    = "tcp"
    cidr_blocks = [var.allowed_cidr]
  }

  # Instance -> internet (Gemini, Groq, Bedrock, Docker Hub, pip)
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ─── Bedrock guardrail: blocks harmful input and output ───────────────────────

resource "aws_bedrock_guardrail" "main" {
  name                      = "${local.name}-guardrail"
  blocked_input_messaging   = "This request was blocked by the safety guardrail."
  blocked_outputs_messaging = "This response was blocked by the safety guardrail."

  content_policy_config {
    filters_config {
      type            = "HATE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "VIOLENCE"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "SEXUAL"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    filters_config {
      type            = "INSULTS"
      input_strength  = "MEDIUM"
      output_strength = "MEDIUM"
    }
    filters_config {
      type            = "MISCONDUCT"
      input_strength  = "HIGH"
      output_strength = "HIGH"
    }
    # prompt attacks (jailbreaks) only make sense on input
    filters_config {
      type            = "PROMPT_ATTACK"
      input_strength  = "HIGH"
      output_strength = "NONE"
    }
  }
}

resource "aws_bedrock_guardrail_version" "main" {
  guardrail_arn = aws_bedrock_guardrail.main.guardrail_arn
}

# ─── Secrets Manager: everything the app reads at startup (app/config.py) ─────

# Password for the API (X-API-Key header). Terraform makes a random one for you.
resource "random_password" "api_key" {
  length  = 32
  special = false
}

# Password for the Postgres container. Postgres is never open to the internet.
resource "random_password" "db" {
  length  = 32
  special = false
}

# The name must stay "research-relay/config", because app/config.py reads exactly this name.
resource "aws_secretsmanager_secret" "config" {
  name                    = "research-relay/config"
  recovery_window_in_days = 0 # allows instant delete + re-create on terraform destroy/apply
}

# Terraform fills the infra values. You replace the REPLACE_ME keys in the AWS console.
# ignore_changes = terraform will not overwrite your keys on the next apply.
# The hostnames (redis, postgres, tensorzero) are the service names in docker-compose.yml.
resource "aws_secretsmanager_secret_version" "config" {
  secret_id = aws_secretsmanager_secret.config.id
  secret_string = jsonencode({
    AWS_REGION                = var.aws_region
    BEDROCK_GUARDRAIL_ID      = aws_bedrock_guardrail.main.guardrail_id
    BEDROCK_GUARDRAIL_VERSION = aws_bedrock_guardrail_version.main.version
    REDIS_URL                 = "redis://redis:6379/0"
    DATABASE_URL              = "postgresql://research_app:${random_password.db.result}@postgres:5432/research"
    TENSORZERO_URL            = "http://tensorzero:3000"
    POSTGRES_PASSWORD         = random_password.db.result
    API_KEY                   = random_password.api_key.result
    GEMINI_API_KEY            = "REPLACE_ME"
    GROQ_API_KEY              = "REPLACE_ME"
    LANGSMITH_API_KEY         = ""
  })

  lifecycle {
    ignore_changes = [secret_string]
  }
}

# ─── S3: a zip of this project, downloaded by the instance on every boot ──────

resource "aws_s3_bucket" "code" {
  bucket        = "${local.name}-code-${data.aws_caller_identity.current.account_id}"
  force_destroy = true # terraform destroy also empties it
}

resource "aws_s3_bucket_public_access_block" "code" {
  bucket                  = aws_s3_bucket.code.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Zips the project folder (everything except terraform/, tests/ and git files)
data "archive_file" "code" {
  type        = "zip"
  source_dir  = "${path.module}/.."
  output_path = "${path.module}/.build/code.zip"
  excludes = [
    "terraform/**", ".git/**", ".github/**", "tests/**",
    "**/__pycache__/**", ".pytest_cache/**",
  ]
}

resource "aws_s3_object" "code" {
  bucket = aws_s3_bucket.code.id
  key    = "code.zip"
  source = data.archive_file.code.output_path
  etag   = data.archive_file.code.output_md5 # re-uploads when any file changes
}

# ─── IAM role for the instance (this is how the app gets AWS access, no keys) ─

resource "aws_iam_role" "ec2" {
  name = "${local.name}-role"
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Action    = "sts:AssumeRole"
      Principal = { Service = "ec2.amazonaws.com" }
    }]
  })
}

resource "aws_iam_role_policy" "ec2" {
  name = "research-relay-access"
  role = aws_iam_role.ec2.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["secretsmanager:GetSecretValue"]
        Resource = aws_secretsmanager_secret.config.arn
      },
      {
        Effect   = "Allow"
        Action   = ["bedrock:ApplyGuardrail"]
        Resource = aws_bedrock_guardrail.main.guardrail_arn
      },
      {
        Effect   = "Allow"
        Action   = ["s3:GetObject"]
        Resource = "${aws_s3_bucket.code.arn}/*"
      },
    ]
  })
}

# Lets you open a terminal on the instance from the AWS console (Session Manager),
# so we never need to open SSH port 22.
resource "aws_iam_role_policy_attachment" "ssm" {
  role       = aws_iam_role.ec2.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

resource "aws_iam_instance_profile" "ec2" {
  name = "${local.name}-profile"
  role = aws_iam_role.ec2.name
}

# ─── The EC2 instance ─────────────────────────────────────────────────────────

locals {
  # Runs ONCE, on the very first boot: installs Docker and sets up start-on-boot.
  user_data = <<-EOT
    #!/bin/bash
    set -e

    # 1. Docker + Docker Compose + Buildx (ARM versions)
    dnf install -y docker jq unzip
    mkdir -p /usr/local/lib/docker/cli-plugins
    curl -sSL https://github.com/docker/compose/releases/download/v2.32.4/docker-compose-linux-aarch64 \
      -o /usr/local/lib/docker/cli-plugins/docker-compose
    curl -sSL https://github.com/docker/buildx/releases/download/v0.20.1/buildx-v0.20.1.linux-arm64 \
      -o /usr/local/lib/docker/cli-plugins/docker-buildx
    chmod +x /usr/local/lib/docker/cli-plugins/*
    systemctl enable --now docker

    # 2. 2 GB swap file: extra safety for the 2 GB RAM instance (embedding model + pip install)
    if [ ! -f /swapfile ]; then
      dd if=/dev/zero of=/swapfile bs=1M count=2048
      chmod 600 /swapfile
      mkswap /swapfile
      echo "/swapfile none swap sw 0 0" >> /etc/fstab
    fi
    swapon -a

    # 3. The script that runs on EVERY boot (so "Start" in the console = app comes up)
    cat > /opt/research-relay-start.sh <<'SCRIPT'
    #!/bin/bash
    set -e
    REGION=${var.aws_region}

    # a) download the latest code
    aws s3 cp s3://${aws_s3_bucket.code.id}/code.zip /tmp/code.zip --region $REGION
    rm -rf /opt/research-relay
    unzip -q /tmp/code.zip -d /opt/research-relay
    cd /opt/research-relay

    # b) read the secret and write .env for docker compose (keys stay on this instance only)
    SECRET=$(aws secretsmanager get-secret-value --secret-id research-relay/config \
      --region $REGION --query SecretString --output text)
    {
      echo "AWS_REGION=$REGION"
      echo "POSTGRES_PASSWORD=$(echo "$SECRET" | jq -r .POSTGRES_PASSWORD)"
      echo "GEMINI_API_KEY=$(echo "$SECRET" | jq -r .GEMINI_API_KEY)"
      echo "GROQ_API_KEY=$(echo "$SECRET" | jq -r .GROQ_API_KEY)"
    } > .env
    chmod 600 .env

    # c) build (fast after the first time, Docker caches it) and start everything
    docker compose up -d --build
    SCRIPT
    chmod +x /opt/research-relay-start.sh

    cat > /etc/systemd/system/research-relay.service <<'UNIT'
    [Unit]
    Description=Research-Relay (docker compose)
    After=docker.service network-online.target
    Wants=network-online.target
    Requires=docker.service

    [Service]
    Type=oneshot
    ExecStart=/opt/research-relay-start.sh
    TimeoutStartSec=1800

    [Install]
    WantedBy=multi-user.target
    UNIT

    systemctl daemon-reload
    systemctl enable research-relay.service
    systemctl start --no-block research-relay.service
  EOT
}

resource "aws_instance" "app" {
  ami                    = data.aws_ssm_parameter.al2023_arm.value
  instance_type          = var.instance_type
  subnet_id              = aws_subnet.public.id
  vpc_security_group_ids = [aws_security_group.app.id]
  iam_instance_profile   = aws_iam_instance_profile.ec2.name

  # replace() removes Windows line endings, in case this file was saved on Windows
  user_data = replace(local.user_data, "\r", "")

  root_block_device {
    volume_size = 20 # GB. Docker images + Postgres data. Kept when the instance is stopped.
    volume_type = "gp3"
    encrypted   = true
  }

  metadata_options {
    http_tokens                 = "required" # IMDSv2 only (safer)
    http_put_response_hop_limit = 2          # lets the Docker containers use the instance role
  }

  # A newer Amazon Linux image must not replace the instance (that would wipe the database)
  lifecycle {
    ignore_changes = [ami, user_data]
  }

  # the secret and the code must exist before the first boot
  depends_on = [
    aws_secretsmanager_secret_version.config,
    aws_s3_object.code,
    aws_iam_role_policy.ec2,
  ]

  tags = { Name = local.name }
}

# ─── Outputs ──────────────────────────────────────────────────────────────────

output "instance_id" {
  description = "Use this to start/stop the instance from CloudShell."
  value       = aws_instance.app.id
}

output "app_url" {
  description = "Only right after apply. The IP changes after every Stop/Start, see the README."
  value       = "http://${aws_instance.app.public_ip}"
}

output "api_key" {
  description = "Run: terraform output -raw api_key"
  value       = random_password.api_key.result
  sensitive   = true
}

output "config_secret_name" {
  description = "Open this in Secrets Manager and replace the REPLACE_ME keys."
  value       = aws_secretsmanager_secret.config.name
}
