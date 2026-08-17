#!/bin/bash
# scripts/validate-migration.sh
# Validates a completed on-premises to AWS migration
# Usage: ./validate-migration.sh <customer_id> <environment> <onprem_mongodb_host>

set -euo pipefail

CUSTOMER_ID="${1:?Usage: $0 <customer_id> <environment> <onprem_mongodb_host>}"
ENVIRONMENT="${2:?}"
ONPREM_HOST="${3:?}"

AWS_REGION="${AWS_REGION:-us-east-1}"
PROJECT_NAME="${PROJECT_NAME:-athennian}"
PASS=0
FAIL=0

check() {
  local description="$1"
  shift
  if "$@" > /dev/null 2>&1; then
    echo "  ✅  $description"
    ((PASS++))
  else
    echo "  ❌  FAILED: $description"
    ((FAIL++))
  fi
}

echo ""
echo "======================================================"
echo "  Migration Validation: $CUSTOMER_ID ($ENVIRONMENT)"
echo "======================================================"
echo ""

# Get MongoDB connection details from Secrets Manager
SECRET=$(aws secretsmanager get-secret-value \
  --secret-id "${PROJECT_NAME}/${ENVIRONMENT}/mongodb/admin" \
  --region "${AWS_REGION}" \
  --query SecretString \
  --output text)

AWS_MONGO_HOST=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['host'])")
AWS_MONGO_PASS=$(echo "$SECRET" | python3 -c "import sys,json; print(json.load(sys.stdin)['password'])")

echo "📊 Database Record Count Validation"

# Count records on source
ONPREM_COUNT=$(mongosh "mongodb://admin:${AWS_MONGO_PASS}@${ONPREM_HOST}:27017/${CUSTOMER_ID}?authSource=admin" \
  --quiet --eval "db.getCollectionNames().map(c => ({name: c, count: db[c].countDocuments()})).forEach(x => print(x.name + ':' + x.count))" 2>/dev/null || echo "connection_failed")

# Count records on destination
AWS_COUNT=$(mongosh "mongodb://admin:${AWS_MONGO_PASS}@${AWS_MONGO_HOST}:27017/${CUSTOMER_ID}?authSource=admin" \
  --quiet --eval "db.getCollectionNames().map(c => ({name: c, count: db[c].countDocuments()})).forEach(x => print(x.name + ':' + x.count))" 2>/dev/null || echo "connection_failed")

if [ "$ONPREM_COUNT" = "$AWS_COUNT" ]; then
  echo "  ✅  Record counts match between on-prem and AWS"
  ((PASS++))
else
  echo "  ❌  Record count mismatch!"
  echo "      On-prem: $ONPREM_COUNT"
  echo "      AWS:     $AWS_COUNT"
  ((FAIL++))
fi

echo ""
echo "🗄️ S3 File Migration Validation"

ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
BUCKET="${PROJECT_NAME}-${ENVIRONMENT}-${CUSTOMER_ID}-data-${ACCOUNT_ID}"

check "S3 bucket accessible" \
  aws s3api head-bucket --bucket "$BUCKET" --region "$AWS_REGION"

# Count objects
S3_OBJECT_COUNT=$(aws s3api list-objects-v2 \
  --bucket "$BUCKET" \
  --query 'length(Contents)' \
  --output text 2>/dev/null || echo "0")

echo "  📁  S3 object count: $S3_OBJECT_COUNT"

echo ""
echo "🌐 Application Connectivity"

check "Application health endpoint" \
  curl -sf "https://${PROJECT_NAME}-${ENVIRONMENT}.example.com/health"

echo ""
echo "======================================================"
echo "  Migration Results: ${PASS} passed, ${FAIL} failed"
echo "======================================================"
echo ""

if [ "$FAIL" -gt 0 ]; then
  echo "❌ Migration validation FAILED — DO NOT proceed with cutover"
  echo "   Review failures above and remediate before cutover."
  exit 1
else
  echo "✅ Migration validation PASSED — Safe to proceed with cutover"
  exit 0
fi
