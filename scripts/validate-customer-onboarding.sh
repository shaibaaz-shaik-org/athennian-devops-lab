#!/bin/bash
# scripts/validate-customer-onboarding.sh
# Validates all resources were created correctly for a customer
# Usage: ./validate-customer-onboarding.sh <customer_id> <environment>

set -euo pipefail

CUSTOMER_ID="${1:?Usage: $0 <customer_id> <environment>}"
ENVIRONMENT="${2:?Usage: $0 <customer_id> <environment>}"
PROJECT_NAME="${PROJECT_NAME:-athennian}"
AWS_REGION="${AWS_REGION:-us-east-1}"

PASS=0
FAIL=0

check() {
  local description="$1"
  local command="$2"
  
  if eval "$command" > /dev/null 2>&1; then
    echo "  ✅  $description"
    ((PASS++))
  else
    echo "  ❌  $description"
    ((FAIL++))
  fi
}

echo ""
echo "============================================================"
echo "  Validating onboarding: $CUSTOMER_ID ($ENVIRONMENT)"
echo "============================================================"
echo ""

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET_PREFIX="${PROJECT_NAME}-${ENVIRONMENT}-${CUSTOMER_ID}"

echo "📦 S3 Buckets"
check "Data bucket exists" \
  "aws s3api head-bucket --bucket ${BUCKET_PREFIX}-data-${ACCOUNT_ID} --region ${AWS_REGION} 2>/dev/null"
check "Uploads bucket exists" \
  "aws s3api head-bucket --bucket ${BUCKET_PREFIX}-uploads-${ACCOUNT_ID} --region ${AWS_REGION} 2>/dev/null"
check "Exports bucket exists" \
  "aws s3api head-bucket --bucket ${BUCKET_PREFIX}-exports-${ACCOUNT_ID} --region ${AWS_REGION} 2>/dev/null"
check "Data bucket has SSE enabled" \
  "aws s3api get-bucket-encryption --bucket ${BUCKET_PREFIX}-data-${ACCOUNT_ID} --region ${AWS_REGION} 2>/dev/null | grep -q 'aws:kms'"
check "Data bucket is not public" \
  "aws s3api get-bucket-acl --bucket ${BUCKET_PREFIX}-data-${ACCOUNT_ID} --region ${AWS_REGION} 2>/dev/null | grep -qv 'AllUsers'"

echo ""
echo "🔑 KMS Keys"
KMS_ALIAS="alias/${PROJECT_NAME}-${ENVIRONMENT}-customer-${CUSTOMER_ID}"
check "Customer KMS key exists" \
  "aws kms describe-key --key-id ${KMS_ALIAS} --region ${AWS_REGION} 2>/dev/null | grep -q '\"Enabled\": true'"

echo ""
echo "👤 IAM"
ROLE_NAME="${PROJECT_NAME}-${ENVIRONMENT}-${CUSTOMER_ID}-app-role"
check "Customer IAM role exists" \
  "aws iam get-role --role-name ${ROLE_NAME} 2>/dev/null | grep -q 'RoleName'"

echo ""
echo "🔒 Secrets Manager"
SECRET_PATH="${PROJECT_NAME}/${ENVIRONMENT}/customers/${CUSTOMER_ID}/db"
check "Customer DB secret exists" \
  "aws secretsmanager describe-secret --secret-id ${SECRET_PATH} --region ${AWS_REGION} 2>/dev/null | grep -q 'ARN'"

echo ""
echo "📊 CloudWatch"
LOG_GROUP="/app/${PROJECT_NAME}/${ENVIRONMENT}/customers/${CUSTOMER_ID}"
check "Customer log group exists" \
  "aws logs describe-log-groups --log-group-name-prefix ${LOG_GROUP} --region ${AWS_REGION} 2>/dev/null | grep -q '\"logGroupName\"'"

echo ""
echo "============================================================"
echo "  Results: ${PASS} passed, ${FAIL} failed"
echo "============================================================"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "❌ Onboarding validation FAILED. Review failures above."
  exit 1
else
  echo "✅ Onboarding validation PASSED. Customer ${CUSTOMER_ID} is ready."
  exit 0
fi
