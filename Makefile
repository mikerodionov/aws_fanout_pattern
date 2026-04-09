VENV    := serverless/.venv
PYTHON  := $(VENV)/bin/python
REGION  ?= eu-west-1

.PHONY: help requirements terraform-init terraform-apply serverless-deploy publish poll destroy

help:
	@echo "Usage: make <target> [REGION=<aws-region>]"
	@echo ""
	@echo "  REGION  AWS region to deploy to (default: us-east-1)"
	@echo ""
	@echo "Targets:"
	@echo "  requirements       Install all local dependencies (npm + pip + serverless)"
	@echo "  terraform-init     Initialize Terraform providers"
	@echo "  terraform-apply    Deploy infrastructure (SNS, SQS, IAM, CloudWatch)"
	@echo "  serverless-deploy  Deploy Lambda functions via Serverless Framework"
	@echo "  publish            Publish a test message to SNS"
	@echo "  poll               Peek at messages in all SQS queues (non-destructive)"
	@echo "  destroy            Remove ALL resources (Serverless + Terraform)"
	@echo ""
	@echo "Examples:"
	@echo "  make terraform-apply REGION=eu-west-1"
	@echo "  make serverless-deploy REGION=ap-southeast-1"

requirements:
	@echo ">>> Creating Python virtual environment..."
	python3 -m venv $(VENV)
	@echo ">>> Installing Python dependencies into venv..."
	$(PYTHON) -m pip install --upgrade pip
	$(PYTHON) -m pip install -r serverless/requirements.txt
	@echo ">>> Installing Serverless Framework v3 globally..."
	npm install -g serverless@3
	@echo ">>> Installing Serverless plugins (serverless-python-requirements)..."
	cd serverless && npm install
	@echo ">>> All requirements installed."

terraform-init:
	cd terraform && terraform init

terraform-apply:
	cd terraform && terraform apply -var "queue_count=3" -var "aws_region=$(REGION)"

serverless-deploy:
	cd serverless && npm install && sls deploy --region $(REGION)

publish:
	AWS_DEFAULT_REGION=$(REGION) $(PYTHON) serverless/publish.py "Hello from Makefile"

poll:
	@echo ">>> Watching SQS queues every 10s (Ctrl+C to stop)..."
	@echo ">>> Legend: Delayed=waiting 60s | InFlight=Lambda processing | Visible=ready to consume"
	@echo ""
	@while true; do \
		echo "─────────────────────────────────────────────────── $$(date '+%H:%M:%S')"; \
		for i in 1 2 3; do \
			URL=$$(python3 -c "import json; d=json.load(open('terraform/outputs.json')); print(d['queues'][$$i-1]['url'])"); \
			ATTRS=$$(aws sqs get-queue-attributes \
				--region $(REGION) \
				--queue-url "$$URL" \
				--attribute-names ApproximateNumberOfMessages ApproximateNumberOfMessagesNotVisible ApproximateNumberOfMessagesDelayed \
				--query "Attributes" \
				--output json 2>/dev/null); \
			VISIBLE=$$(echo $$ATTRS | python3 -c "import sys,json; print(json.load(sys.stdin).get('ApproximateNumberOfMessages','?'))"); \
			INFLIGHT=$$(echo $$ATTRS | python3 -c "import sys,json; print(json.load(sys.stdin).get('ApproximateNumberOfMessagesNotVisible','?'))"); \
			DELAYED=$$(echo $$ATTRS | python3 -c "import sys,json; print(json.load(sys.stdin).get('ApproximateNumberOfMessagesDelayed','?'))"); \
			echo "  Queue $$i → Delayed: $$DELAYED  |  InFlight: $$INFLIGHT  |  Visible: $$VISIBLE"; \
		done; \
		echo ""; \
		sleep 10; \
	done

destroy:
	@echo ">>> [1/2] Removing Serverless stack (Lambdas, API Gateway)..."
	cd serverless && sls remove --region $(REGION)
	@echo ">>> [2/2] Destroying Terraform infrastructure (SNS, SQS, DLQ, DynamoDB, IAM)..."
	cd terraform && terraform destroy -var "queue_count=3" -var "aws_region=$(REGION)" -auto-approve
	@echo ">>> All resources destroyed."
