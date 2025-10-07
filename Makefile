.PHONY: terraform-init terraform-apply serverless-deploy publish

terraform-init:
	cd terraform && terraform init

terraform-apply:
	cd terraform && terraform apply -var "queue_count=3"

serverless-deploy:
	cd serverless && sls deploy

publish:
	cd serverless && python publish.py "Hello from Makefile"
