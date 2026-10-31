#!/bin/bash
# One-time setup: creates the S3 bucket where Terraform keeps its state file.
# Run it once, in AWS CloudShell or any terminal where `aws` is logged in.
set -e

REGION=${1:-ap-southeast-2}
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="research-relay-tfstate-$ACCOUNT_ID"   # bucket names are global, so we add your account id

echo "Creating S3 bucket: $BUCKET in region: $REGION"
if [ "$REGION" = "us-east-1" ]; then
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" 2>/dev/null \
    && echo "Bucket created." || echo "Bucket already exists, continuing."
else
  aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
    --create-bucket-configuration LocationConstraint="$REGION" 2>/dev/null \
    && echo "Bucket created." || echo "Bucket already exists, continuing."
fi

echo "Turning on versioning (so an old state file can be recovered)..."
aws s3api put-bucket-versioning --bucket "$BUCKET" --versioning-configuration Status=Enabled

echo "Blocking public access..."
aws s3api put-public-access-block --bucket "$BUCKET" --public-access-block-configuration \
  BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo ""
echo "Bootstrap complete. Next:"
echo "  cd terraform && chmod +x tf.sh && ./tf.sh apply"
