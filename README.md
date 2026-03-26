# AWS Fargate + DynamoDB + SQS Fullstack Starter

React UI + Spring Boot backend designed for an AWS-first deployment model.

## Live endpoints

The values below are placeholders (masked):

- UI: https://{frontend-cloudfront-domain}
- API: https://{api-cloudfront-domain}

## Local Docker requirement

Local Docker is not required for AWS deployment in this repo.
Backend image build/push happens in AWS CodeBuild via `artifacts/aws/deploy.sh`.

## Screenshots

Main UI:

![Spring Boot Job Runner UI](assets/screenshots/app-ui.png)

## What this project does

- React UI submits jobs and polls status updates.
- Spring Boot API supports two runtime modes:
	- `LOCAL_MEMORY`: in-memory jobs for local development.
	- `AWS_DYNAMODB_SQS`: writes jobs to DynamoDB and enqueues processing via SQS.
- In AWS mode, queued jobs are processed asynchronously and transition:
	1. `PENDING`
	2. `PROCESSING`
	3. `COMPLETED`

## API

- `POST /jobs` -> accepts `{ "message": "..." }`, returns `202` with `{ jobId, status }`
- `GET /jobs/{jobId}` -> returns current job state
- `GET /jobs/mode` -> returns backend mode (`LOCAL_MEMORY` or `AWS_DYNAMODB_SQS`)

## Project structure

- `frontend`: React + TypeScript + Vite
- `backend`: Spring Boot API, queue worker loop, DynamoDB/SQS integration
- `artifacts/aws`: deploy artifacts for ECS Fargate + DynamoDB + SQS

## Local development

Backend:

```bash
cd backend
mvn spring-boot:run
```

Frontend:

```bash
cd frontend
npm install
cp .env.example .env.local
npm run dev
```

Root scripts:

```bash
npm run dev
npm run dev:backend
```

## AWS mode configuration

Set these environment variables for the backend container/task:

- `AWS_JOBS_ENABLED=true`
- `AWS_JOBS_TABLE_NAME=<dynamodb-table-name>`
- `AWS_JOBS_QUEUE_URL=<sqs-queue-url>`
- `AWS_JOBS_QUEUE_POLLING_ENABLED=true`

When `AWS_JOBS_ENABLED=true`, create/read operations use DynamoDB and async processing uses SQS.

## AWS artifacts included

- `backend/Dockerfile`: container image build for ECS/Fargate
- `artifacts/aws/infra.yaml`: CloudFormation stack for DynamoDB, SQS, ECS, ALB, IAM, logs
- `artifacts/aws/task-definition.json`: task definition template
- `artifacts/aws/frontend-infra.yaml`: CloudFormation stack for S3 + CloudFront frontend hosting
- `artifacts/aws/deploy.sh`: backend deploy helper (builds image in AWS CodeBuild, then deploys API stack)
- `artifacts/aws/deploy-frontend.sh`: helper script to deploy frontend infra and static assets

## Deploy backend (ECS Fargate + ALB)

```bash
chmod +x artifacts/aws/deploy.sh
./artifacts/aws/deploy.sh <stack-name> <region> <account-id> <vpc-id> <subnet-a> <subnet-b>
```

The backend deploy script uses AWS CodeBuild for image build/push, so local Docker is not required.

This outputs both API URLs:

- `ApiBaseUrl`: ALB HTTP URL (`http://...elb.amazonaws.com`)
- `ApiHttpsUrl`: CloudFront HTTPS URL (`https://...cloudfront.net`)

Use `ApiHttpsUrl` for browser-based frontend deployments to avoid mixed-content blocking.

## AWS deployment gotchas

- Run deploy commands from repo root so relative paths like `artifacts/aws/infra.yaml` resolve correctly.
- If frontend is on HTTPS and API is HTTP, the browser blocks requests (`Failed to fetch`) because of mixed content.
- Use stack output `ApiHttpsUrl` as `VITE_API_BASE_URL` when deploying frontend.
- First-time ECS service stabilization can take 15-30 minutes while tasks register with ALB and old targets drain.
- Expected job transition (`PROCESSING` -> `COMPLETED`) is a few seconds after warm-up; if it drifts much higher, redeploy latest backend image and verify scheduler concurrency settings.
- `CREATE_IN_PROGRESS` on CloudFormation can continue even when ECS already shows `runningCount=desiredCount`.
- If ECS events show `CannotPullContainerError ... image ...:latest not found`, your image was not pushed to ECR yet.

Quick checks:

```bash
aws cloudformation describe-stacks --stack-name <stack-name> --region <region> --query "Stacks[0].StackStatus" --output text
aws ecs describe-services --cluster <ecs-cluster-name> --services <service-name> --region <region> --query "services[0].[runningCount,desiredCount,deployments[0].rolloutState]" --output text
```

When image is missing in ECR:

1. Re-run CodeBuild image build and wait for `SUCCEEDED`.
2. Force ECS service to redeploy:

```bash
aws ecs update-service --cluster <ecs-cluster-name> --service <service-name> --force-new-deployment --region <region>
```

Rate limit note:

- If CodeBuild fails with Docker Hub `429 Too Many Requests`, use AWS Public ECR mirror base images in `backend/Dockerfile` (already configured in this repo).

## First-time backend deploy checklist

Use this checklist for the first deployment in a new AWS account/region.

1. Confirm AWS auth and region.
2. Create/select a VPC and two public subnets in different AZs.
3. Ensure Internet Gateway and route table allow `0.0.0.0/0` egress.
4. Ensure both subnets have auto-assign public IP enabled.
5. Create S3 bucket for source zip uploads.
6. Create ECR repo `aws-springboot-jobs`.
7. Create IAM role for CodeBuild and attach permissions for S3/ECR/Logs.
8. Upload source zip (includes `buildspec.yml` and backend source).
9. Run CodeBuild and wait for image push success.
10. Deploy CloudFormation backend stack from `artifacts/aws/infra.yaml`.
11. If ECS service is stuck, check target health and ECS service events.
12. Retrieve `ApiBaseUrl` from stack outputs and run smoke test.

Helpful commands:

```bash
aws cloudformation describe-stacks --stack-name <backend-stack-name> --region <region> --query "Stacks[0].Outputs[?OutputKey=='ApiBaseUrl'].OutputValue" --output text
aws cloudformation describe-stacks --stack-name <backend-stack-name> --region <region> --query "Stacks[0].Outputs[?OutputKey=='ApiHttpsUrl'].OutputValue" --output text
npm run smoke:aws -- <api-base-url> <frontend-url>
```

## Deploy frontend (S3 + CloudFront)

```bash
chmod +x artifacts/aws/deploy-frontend.sh
./artifacts/aws/deploy-frontend.sh \
	<frontend-stack-name> \
	<region> \
	<globally-unique-site-bucket-name> \
	<api-base-url-from-backend-stack> \
	frontend
```

The frontend script will:

- Deploy/update S3 + CloudFront infrastructure.
- Build the React app with `VITE_API_BASE_URL` set to your backend ALB URL.
- Upload `frontend/dist` to S3.
- Invalidate CloudFront cache.

Use the `FrontendUrl` stack output as your public UI URL.

## One script: down/up

Use one script for both zero-cost teardown and full recreate:

```bash
chmod +x scripts/manage-aws-env.sh
```

Run in this order.

1. Discover and export base values:

```bash
export ACCOUNT_ID="$(aws sts get-caller-identity --query 'Account' --output text)"
export REGION="$(aws configure get region)"

# if REGION is empty, set it manually
# export REGION=us-east-1
```

2. Discover network values for `up`:

```bash
aws ec2 describe-vpcs --region "$REGION" --query 'Vpcs[].{VpcId:VpcId,Cidr:CidrBlock,IsDefault:IsDefault}' --output table

# choose one VPC ID from above
export VPC_ID=<vpc-id>

aws ec2 describe-subnets --region "$REGION" --filters Name=vpc-id,Values="$VPC_ID" --query 'Subnets[].{SubnetId:SubnetId,AZ:AvailabilityZone,CIDR:CidrBlock}' --output table

# choose two subnet IDs from different AZs
export SUBNET_A=<subnet-a>
export SUBNET_B=<subnet-b>
```

3. Set stack/bucket names (customize once):

```bash
export SITE_BUCKET_NAME="aws-springboot-frontend-${ACCOUNT_ID}-${REGION}-<suffix>"
export BACKEND_STACK=<backend-stack-name>
export FRONTEND_STACK=<frontend-stack-name>
```

4. Bring everything up (rebuild backend image in CodeBuild, deploy backend + frontend):

```bash
ACCOUNT_ID="$ACCOUNT_ID" REGION="$REGION" VPC_ID="$VPC_ID" SUBNET_A="$SUBNET_A" SUBNET_B="$SUBNET_B" SITE_BUCKET_NAME="$SITE_BUCKET_NAME" BACKEND_STACK="$BACKEND_STACK" FRONTEND_STACK="$FRONTEND_STACK" ./scripts/manage-aws-env.sh up
```

5. Bring everything down to near-zero app cost (deletes backend/frontend stacks and app buckets, removes build resources):

```bash
ACCOUNT_ID="$ACCOUNT_ID" REGION="$REGION" SITE_BUCKET_NAME="$SITE_BUCKET_NAME" BACKEND_STACK="$BACKEND_STACK" FRONTEND_STACK="$FRONTEND_STACK" ./scripts/manage-aws-env.sh down
```

Notes:

- `up` requires `VPC_ID`, `SUBNET_A`, `SUBNET_B`.
- `down` intentionally does not delete your VPC/subnets.
- Script prints final API HTTPS URL and frontend URL after successful `up`.

## Smoke tests

Run these as separate checks depending on what you want to verify.

Local backend API check (backend must be running):

```bash
npm run smoke:local:backend
```

Local frontend availability check (frontend dev server must be running):

```bash
npm run smoke:local:ui
```

AWS hosted check (API + CloudFront frontend):

```bash
npm run smoke:aws -- <api-base-url> <frontend-url>
```

Examples:

```bash
npm run smoke:aws -- http://my-api-alb.amazonaws.com https://d123456abcdef.cloudfront.net
```

Environment overrides:

- `API_BASE_URL` for local backend smoke test (default: `http://localhost:8080`)
- `UI_BASE_URL` / `ALT_UI_BASE_URL` for local UI smoke test (defaults: `http://localhost:5173` and `http://localhost:5174`)
