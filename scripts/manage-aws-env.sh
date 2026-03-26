#!/usr/bin/env bash
set -euo pipefail

ACTION="${1:-}"

if [[ "${ACTION}" != "up" && "${ACTION}" != "down" ]]; then
  echo "Usage: $0 <up|down>"
  echo "Required env vars for up: VPC_ID, SUBNET_A, SUBNET_B"
  echo "Optional env vars: REGION, ACCOUNT_ID, BACKEND_STACK, FRONTEND_STACK, SITE_BUCKET_NAME"
  exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

REGION="${REGION:-us-east-1}"
ACCOUNT_ID="${ACCOUNT_ID:-}"
BACKEND_STACK="${BACKEND_STACK:-aws-springboot-backend}"
FRONTEND_STACK="${FRONTEND_STACK:-aws-springboot-frontend}"

if [[ -z "${ACCOUNT_ID}" ]]; then
  ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text)"
fi

BUILD_BUCKET="aws-springboot-build-${ACCOUNT_ID}-${REGION}"
SITE_BUCKET_NAME="${SITE_BUCKET_NAME:-aws-springboot-frontend-${ACCOUNT_ID}-${REGION}}"

stack_exists() {
  local stack_name="$1"
  aws cloudformation describe-stacks --stack-name "${stack_name}" --region "${REGION}" >/dev/null 2>&1
}

delete_stack_if_exists() {
  local stack_name="$1"
  if stack_exists "${stack_name}"; then
    echo "Deleting stack: ${stack_name}"
    aws cloudformation delete-stack --stack-name "${stack_name}" --region "${REGION}"
    aws cloudformation wait stack-delete-complete --stack-name "${stack_name}" --region "${REGION}"
    echo "Deleted stack: ${stack_name}"
  else
    echo "Stack not found, skipping: ${stack_name}"
  fi
}

if [[ "${ACTION}" == "down" ]]; then
  delete_stack_if_exists "${FRONTEND_STACK}"
  delete_stack_if_exists "${BACKEND_STACK}"

  echo "Cleaning optional build resources"

  aws codebuild delete-project --name aws-springboot-image-build --region "${REGION}" >/dev/null 2>&1 || true
  aws ecr delete-repository --repository-name aws-springboot-jobs --force --region "${REGION}" >/dev/null 2>&1 || true

  if aws s3api head-bucket --bucket "${BUILD_BUCKET}" >/dev/null 2>&1; then
    aws s3 rm "s3://${BUILD_BUCKET}" --recursive --region "${REGION}" >/dev/null 2>&1 || true
    aws s3 rb "s3://${BUILD_BUCKET}" --force --region "${REGION}" >/dev/null 2>&1 || true
  fi

  if aws s3api head-bucket --bucket "${SITE_BUCKET_NAME}" >/dev/null 2>&1; then
    aws s3 rm "s3://${SITE_BUCKET_NAME}" --recursive --region "${REGION}" >/dev/null 2>&1 || true
    aws s3 rb "s3://${SITE_BUCKET_NAME}" --force --region "${REGION}" >/dev/null 2>&1 || true
  fi

  echo "Environment is down."
  echo "No ECS/ALB/CloudFront/S3 app buckets remain from this stack pair."
  exit 0
fi

# ACTION=up
VPC_ID="${VPC_ID:-}"
SUBNET_A="${SUBNET_A:-}"
SUBNET_B="${SUBNET_B:-}"

if [[ -z "${VPC_ID}" || -z "${SUBNET_A}" || -z "${SUBNET_B}" ]]; then
  echo "For 'up', set VPC_ID, SUBNET_A, SUBNET_B."
  exit 1
fi

echo "Deploying backend stack"
"${REPO_ROOT}/artifacts/aws/deploy.sh" "${BACKEND_STACK}" "${REGION}" "${ACCOUNT_ID}" "${VPC_ID}" "${SUBNET_A}" "${SUBNET_B}"

API_HTTPS_URL="$(aws cloudformation describe-stacks \
  --stack-name "${BACKEND_STACK}" \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='ApiHttpsUrl'].OutputValue" \
  --output text)"

echo "Deploying frontend stack"
"${REPO_ROOT}/artifacts/aws/deploy-frontend.sh" \
  "${FRONTEND_STACK}" \
  "${REGION}" \
  "${SITE_BUCKET_NAME}" \
  "${API_HTTPS_URL}" \
  frontend

FRONTEND_URL="$(aws cloudformation describe-stacks \
  --stack-name "${FRONTEND_STACK}" \
  --region "${REGION}" \
  --query "Stacks[0].Outputs[?OutputKey=='FrontendUrl'].OutputValue" \
  --output text)"

echo "Environment is up."
echo "API HTTPS URL: ${API_HTTPS_URL}"
echo "Frontend URL : ${FRONTEND_URL}"
