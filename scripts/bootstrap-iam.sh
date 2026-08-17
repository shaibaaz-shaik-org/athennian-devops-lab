#!/bin/bash
# bootstrap-iam.sh — attach policies to GitHub Actions IAM role
set -e

ROLE="athennian-devops-lab-github-actions"

POLICIES=(
  "arn:aws:iam::aws:policy/AmazonVPCFullAccess"
  "arn:aws:iam::aws:policy/AmazonEC2FullAccess"
  "arn:aws:iam::aws:policy/ElasticLoadBalancingFullAccess"
  "arn:aws:iam::aws:policy/AmazonS3FullAccess"
  "arn:aws:iam::aws:policy/AmazonDynamoDBFullAccess"
  "arn:aws:iam::aws:policy/CloudWatchFullAccess"
  "arn:aws:iam::aws:policy/AmazonSNSFullAccess"
  "arn:aws:iam::aws:policy/SecretsManagerReadWrite"
  "arn:aws:iam::aws:policy/AWSWAFv2FullAccess"
)

for policy in "${POLICIES[@]}"; do
  aws iam attach-role-policy \
    --role-name "$ROLE" \
    --policy-arn "$policy" 2>&1 \
    | grep -v "^$" || true
  echo "  attached: $policy"
done

# Also attach IAM permissions (needed for Terraform to create roles/policies)
cat > /tmp/iam-inline.json << 'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "iam:*Role*",
        "iam:*Policy*",
        "iam:*InstanceProfile*",
        "iam:*OpenIDConnect*",
        "iam:PassRole",
        "iam:GetUser",
        "kms:*"
      ],
      "Resource": "*"
    }
  ]
}
EOF

aws iam put-role-policy \
  --role-name "$ROLE" \
  --policy-name "athennian-terraform-iam-kms" \
  --policy-document file:///tmp/iam-inline.json

echo ""
echo "Done. All policies attached to: $ROLE"
