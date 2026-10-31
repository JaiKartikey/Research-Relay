@echo off
REM One-time setup: creates the S3 bucket where Terraform keeps its state file.
setlocal

set REGION=ap-southeast-2
for /f %%i in ('aws sts get-caller-identity --query Account --output text') do set ACCOUNT_ID=%%i
set BUCKET=research-relay-tfstate-%ACCOUNT_ID%

echo Creating S3 bucket: %BUCKET% in region: %REGION%
aws s3api create-bucket --bucket %BUCKET% --region %REGION% --create-bucket-configuration LocationConstraint=%REGION% 2>nul
if %errorlevel% equ 0 (
    echo Bucket created.
) else (
    echo Bucket already exists, continuing.
)

echo Turning on versioning...
aws s3api put-bucket-versioning --bucket %BUCKET% --versioning-configuration Status=Enabled

echo Blocking public access...
aws s3api put-public-access-block --bucket %BUCKET% --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true

echo.
echo Bootstrap complete. Next:
echo   cd terraform
echo   terraform init -backend-config="bucket=%BUCKET%"
echo   terraform apply

endlocal
