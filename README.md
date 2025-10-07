# AWS Fanout Pattern (SNS -> SQS) with Terraform and Python Lambdas

This repository demonstrates an AWS fanout architecture built with Terraform and Python Lambdas. It includes an HTTP API that publishes messages to an SNS topic which fans out to multiple SQS queues. The publisher Lambda persists messages to DynamoDB. The repository also contains observability components (CloudWatch Log Groups, metric filters and alarms) and a lightweight `sqs_logger` Lambda that ensures log streams are created for SQS and SNS log groups.

## What this project provides

- SNS topic (fanout) that publishes to multiple SQS queues
- Publisher Lambda (exposed via API Gateway HTTP API) that writes to DynamoDB and publishes to SNS
- SQS queues (multiple) with subscriptions to the SNS topic
- CloudWatch Log Groups for API Gateway, SNS and SQS
- CloudWatch Metric Filters and Alarms for important events
- `sqs_logger` Lambda that consumes SQS messages and writes to `/aws/sqs/<queue>` log groups and subscribes to SNS to create `/aws/sns/<topic>` log streams (useful for metric filters)

## Prerequisites

- Terraform (>= 1.0 recommended)
- AWS CLI configured with credentials and default region
- Python 3.11 (for local lambda packaging if you want to modify code)

## Quick structure

```
aws_fanout_patterns/
├─ terraform/
│  ├─ main.tf                # Terraform configuration (SNS, SQS, Lambda, IAM, CloudWatch)
│  ├─ lambda/
│  │  ├─ publisher.py        # Publisher Lambda: writes to DynamoDB and publishes to SNS
│  │  ├─ sqs_logger.py       # Logger Lambda: consumes SQS and writes into CloudWatch log groups
│  │  ├─ test_fail.py        # (optional) test lambda used during debugging
│  ├─ outputs.json           # Terraform writes runtime outputs here after apply
├─ README.md
```

## Deploy (step-by-step)

1. Open a terminal and change to the `terraform` directory:

```bash
cd /home/chamo/Documents/aws_fanout_patterns/terraform
```

2. Initialize Terraform providers:

```bash
terraform init
```

3. Review the plan (optional):

```bash
terraform plan -out=tfplan
terraform show -json tfplan | jq .   # optional: inspect the planned changes
```

4. Apply the configuration:

```bash
terraform apply -auto-approve
```

Notes:
- The Terraform configuration uses a small `local-exec` provisioner to set certain SNS topic attributes via the AWS CLI. Ensure the environment running Terraform has the AWS CLI and correct credentials/region configuration. The provisioner has retry logic to be resilient to transient failures.

## Test examples (how to exercise the stack)

1. Publish a message via the HTTP API (publisher Lambda)

```bash
API_ENDPOINT=$(jq -r .api_endpoint outputs.json)
curl -s -X POST "$API_ENDPOINT/publish" -H 'Content-Type: application/json' -d '{"text":"Hello from API"}' -w '\nHTTP_STATUS:%{http_code}\n'
```

Expected: A JSON response containing DynamoDB id and SNS messageId.

2. Publish directly to SNS (useful to exercise fanout)

```bash
aws sns publish --region us-east-1 --topic-arn $(jq -r .sns_topic_arn outputs.json) --message '{"test":"direct-sns-publish"}'
```

3. Check CloudWatch log streams for SQS and SNS log groups to validate that streams were created by the `sqs_logger` Lambda:

```bash
aws logs describe-log-streams --region us-east-1 --log-group-name "/aws/sqs/<your-queue-name>" --max-items 5
aws logs describe-log-streams --region us-east-1 --log-group-name "/aws/sns/<your-topic-name>" --max-items 5
```

4. Verify custom metrics and alarms (example for SQS errors):

```bash
aws cloudwatch get-metric-statistics --region us-east-1 --namespace 'Custom/Fanout/SQS' --metric-name 'SQSLogErrors-0' --start-time "$(date -u -d '5 minutes ago' +%Y-%m-%dT%H:%M:%SZ)" --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --period 60 --statistics Sum

aws cloudwatch describe-alarms --region us-east-1 --alarm-name-prefix 'sqs-log-errors'
```

## Cleanup

To destroy everything (be careful):

```bash
cd terraform
terraform destroy -auto-approve
```

## Notes and next steps

- The `sqs_logger` Lambda is intentionally simple and writes messages to CloudWatch log groups. In production you might prefer to:
  - Give the logger Lambda its own execution role with restricted permissions instead of reusing a shared role.
  - Use structured JSON logs so CloudWatch metric filters are more precise.
  - Configure SNS subscription confirmations and security settings depending on your environment.

If you want, I can:
- Add an `email` subscription to the alarms topic to receive notifications.
- Restrict IAM policies to the exact ARNs of the log groups instead of `*`.
- Split roles so each Lambda has its own least-privilege role.

---

If anything in the README is ambiguous or you'd like additional examples (e.g., using LocalStack for offline tests), tell me which section to expand.
AWS Fanout Pattern (SNS -> multiple SQS -> Lambda consumers)

Estructura:

- terraform/: configura SNS + N SQS + outputs.json
- serverless/: funciones Lambda en Python y script para publicar mensajes

Pre-requisitos:

- AWS credentials configuradas (env vars o perfil)
- Terraform >= 1.0
- Serverless Framework v3 y plugin `serverless-python-requirements`
- Python 3.11 para el runtime

Flujo de despliegue resumido:

1. cd terraform && terraform init && terraform apply -var "queue_count=3"
2. cd ../serverless && sls deploy
3. cd serverless && python publish.py "mensaje de prueba"
