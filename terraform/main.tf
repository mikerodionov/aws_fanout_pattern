resource "aws_sns_topic" "fanout" {
  name = "fanout-topic-${random_id.suffix.hex}"
}

resource "random_id" "suffix" {
  byte_length = 4
}

# Dead-letter queues — one per main queue
resource "aws_sqs_queue" "dlqs" {
  count = var.queue_count

  name                      = "${var.queue_name_prefix}-${count.index + 1}-dlq-${random_id.suffix.hex}"
  message_retention_seconds = 1209600 # 14 days to allow investigation
}

resource "aws_sqs_queue" "queues" {
  count = var.queue_count

  name                      = "${var.queue_name_prefix}-${count.index + 1}-${random_id.suffix.hex}"
  delay_seconds              = 60      # messages sit in queue 60s before consumers can pick them up
  visibility_timeout_seconds = 30
  message_retention_seconds  = 1209600 # 14 days

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlqs[count.index].arn
    maxReceiveCount     = 3
  })
}

resource "aws_sns_topic_subscription" "to_queue" {
  count = var.queue_count

  topic_arn = aws_sns_topic.fanout.arn
  protocol  = "sqs"
  endpoint  = aws_sqs_queue.queues[count.index].arn

  # For SQS subscriptions, we need to set raw_message_delivery
  raw_message_delivery = true
}

# Allow SNS to send messages to SQS queues by creating proper policy on each SQS queue
resource "aws_sqs_queue_policy" "allow_sns" {
  count = var.queue_count

  queue_url = aws_sqs_queue.queues[count.index].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid = "Allow-SNS-SendMessage"
        Effect = "Allow"
        Principal = { AWS = "*" }
        Action = "sqs:SendMessage"
        Resource = aws_sqs_queue.queues[count.index].arn
        Condition = {
          ArnEquals = {
            "aws:SourceArn" = aws_sns_topic.fanout.arn
          }
        }
      }
    ]
  })
}

# Produce outputs object for serverless to consume
locals {
  queues = [for q in aws_sqs_queue.queues : {
    name = q.name
    url  = q.id
    arn  = q.arn
  }]

  dlqs = [for q in aws_sqs_queue.dlqs : {
    name = q.name
    url  = q.id
    arn  = q.arn
  }]

  base_outputs = {
    sns_topic_arn        = aws_sns_topic.fanout.arn
    queues               = local.queues
    dlqs                 = local.dlqs
    dynamodb_table_name  = aws_dynamodb_table.messages.name
    dynamodb_table_arn   = aws_dynamodb_table.messages.arn
    # Flat named keys for Serverless Framework (no array index support)
    queue_1_arn          = aws_sqs_queue.queues[0].arn
    queue_2_arn          = aws_sqs_queue.queues[1].arn
    queue_3_arn          = aws_sqs_queue.queues[2].arn
  }
}

# ---------------------------
# Lambda publisher + HTTP API
# ---------------------------

data "archive_file" "publisher_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/publisher.py"
  output_path = "${path.module}/lambda/publisher.zip"
}

# Archive for test failure Lambda
data "archive_file" "test_fail_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/test_fail.py"
  output_path = "${path.module}/lambda/test_fail.zip"
}

# Archive for SQS logger Lambda
data "archive_file" "sqs_logger_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/sqs_logger.py"
  output_path = "${path.module}/lambda/sqs_logger.zip"
}

resource "aws_iam_role" "lambda_exec" {
  name = "lambda-exec-${random_id.suffix.hex}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Action = "sts:AssumeRole",
        Effect = "Allow",
        Principal = { Service = "lambda.amazonaws.com" },
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_policy" "sns_publish_policy" {
  name = "sns-publish-${random_id.suffix.hex}"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = ["sns:Publish"],
        Resource = aws_sns_topic.fanout.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_sns_publish" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.sns_publish_policy.arn
}

# DynamoDB table for messages
resource "aws_dynamodb_table" "messages" {
  name         = "fanout-messages-${random_id.suffix.hex}"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "id"

  attribute {
    name = "id"
    type = "S"
  }

  tags = {
    Name = "fanout-messages-${random_id.suffix.hex}"
  }
}

resource "aws_iam_policy" "dynamodb_put_policy" {
  name = "dynamodb-put-${random_id.suffix.hex}"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "dynamodb:PutItem",
          "dynamodb:UpdateItem"
        ],
        Resource = aws_dynamodb_table.messages.arn
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_dynamodb_put" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.dynamodb_put_policy.arn
}

# Policy to allow Lambda to consume from SQS queues (required for event source mappings)
resource "aws_iam_policy" "lambda_sqs_consume_policy" {
  name = "lambda-sqs-consume-${random_id.suffix.hex}"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility"
        ],
        Resource = [for q in aws_sqs_queue.queues : q.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_sqs_consume_attach" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_sqs_consume_policy.arn
}

# Additional policy to allow writing to CloudWatch Logs for the logger lambda
resource "aws_iam_policy" "logger_logs_policy" {
  name = "logger-logs-policy-${random_id.suffix.hex}"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents",
          "logs:DescribeLogStreams"
        ],
        Resource = "*"
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_logger_logs_attach" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.logger_logs_policy.arn
}

# SQS logger Lambda
resource "aws_lambda_function" "sqs_logger" {
  filename         = data.archive_file.sqs_logger_zip.output_path
  function_name    = "sqs-logger-${random_id.suffix.hex}"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "sqs_logger.handler"
  runtime          = "python3.13"
  source_code_hash = data.archive_file.sqs_logger_zip.output_base64sha256
}

# sqs_logger is invoked by the Serverless consumer Lambdas via the SQS event source
# mappings defined in serverless.yml — no separate event source mapping here to avoid
# competing consumers on the same queues (each SQS message can only be delivered once).

resource "aws_lambda_function" "publisher" {
  filename         = data.archive_file.publisher_zip.output_path
  function_name    = "publisher-${random_id.suffix.hex}"
  role             = aws_iam_role.lambda_exec.arn
  handler          = "publisher.handler"
  runtime          = "python3.13"
  source_code_hash = data.archive_file.publisher_zip.output_base64sha256
  environment {
    variables = {
      SNS_TOPIC_ARN = aws_sns_topic.fanout.arn
    }
  }
}

# Test Lambda that always fails to force SNS delivery-failure logs

# Alarms SNS topic for notifications
resource "aws_sns_topic" "alarms" {
  name = "fanout-alarms-${random_id.suffix.hex}"
}

# Metric filter to count exceptions in the test lambda logs


# CloudWatch Log Group for Lambda (set retention)
# Lambda log group is created automatically by Lambda; retention can be managed separately if desired.

resource "aws_apigatewayv2_api" "http_api" {
  name          = "fanout-http-api-${random_id.suffix.hex}"
  protocol_type = "HTTP"
}

resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.http_api.id
  integration_type = "AWS_PROXY"
  integration_uri  = aws_lambda_function.publisher.invoke_arn
  integration_method = "POST"
}

resource "aws_apigatewayv2_route" "publish_route" {
  api_id    = aws_apigatewayv2_api.http_api.id
  route_key = "POST /publish"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}



# Enable API Gateway access logs by creating a Log Group and setting access_log_settings
resource "aws_cloudwatch_log_group" "apigw_access_log" {
  name              = "/aws/apigateway/${aws_apigatewayv2_api.http_api.name}"
  retention_in_days = 14
}

# CloudWatch Log Group for SNS topic (optional – SNS publishes some operational logs into CloudWatch for certain features)
resource "aws_cloudwatch_log_group" "sns_log" {
  name              = "/aws/sns/${aws_sns_topic.fanout.name}"
  retention_in_days = 14
}

# CloudWatch Log Groups per SQS queue (useful for routing logs or exporting)
resource "aws_cloudwatch_log_group" "sqs_logs" {
  for_each = { for idx, q in aws_sqs_queue.queues : idx => q }

  name              = "/aws/sqs/${each.value.name}"
  retention_in_days = 14
}

# Create CloudWatch Log Metric Filters for SQS log groups to surface errors or important events
resource "aws_cloudwatch_log_metric_filter" "sqs_error_filters" {
  for_each = aws_cloudwatch_log_group.sqs_logs

  name           = "SQSLogErrors-${random_id.suffix.hex}-${each.key}"
  log_group_name = each.value.name

  # Pattern: look for a simple error keyword in logs (valid CloudWatch filter syntax)
  pattern = "ERROR"

  metric_transformation {
    name      = "SQSLogErrors-${each.key}"
    namespace = "Custom/Fanout/SQS"
    value     = "1"
  }
}

# Create CloudWatch Metric Alarms for the SQS error metric (per-queue)
resource "aws_cloudwatch_metric_alarm" "sqs_log_errors_alarm" {
  for_each = aws_cloudwatch_log_metric_filter.sqs_error_filters

  alarm_name          = "sqs-log-errors-${random_id.suffix.hex}-${each.key}"
  namespace           = each.value.metric_transformation[0].namespace
  metric_name         = each.value.metric_transformation[0].name
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_description   = "Alarm when SQS log group ${each.key} contains error traces"

  alarm_actions = [aws_sns_topic.alarms.arn]
}

resource "aws_apigatewayv2_stage" "default_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.apigw_access_log.arn
    format = jsonencode({
      requestId = "$context.requestId",
      ip = "$context.identity.sourceIp",
      requestTime = "$context.requestTime",
      httpMethod = "$context.httpMethod",
      routeKey = "$context.routeKey",
      status = "$context.status",
      responseLatency = "$context.responseLatency"
    })
  }
}

resource "aws_lambda_permission" "apigw_invoke" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.publisher.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

# IAM Role for SNS delivery status logging to CloudWatch Logs
resource "aws_iam_role" "sns_delivery_role" {
  name = "sns-delivery-role-${random_id.suffix.hex}"
  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Principal = { Service = "sns.amazonaws.com" },
        Action = "sts:AssumeRole"
      }
    ]
  })
}

resource "aws_iam_role_policy" "sns_delivery_policy" {
  name = "sns-delivery-policy-${random_id.suffix.hex}"
  role = aws_iam_role.sns_delivery_role.id

  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ],
        Resource = "*"
      }
    ]
  })
}

# Use local-exec to set topic attributes that enable delivery status logging for SQS endpoints.
# This requires the AWS CLI configured where Terraform runs.
resource "null_resource" "sns_set_delivery_attrs" {
  provisioner "local-exec" {
  command = <<EOT
# Robust SNS topic attributes setter with retries and safe bash options
set -euo pipefail
REGION="${var.aws_region}"
TOPIC_ARN="${aws_sns_topic.fanout.arn}"
ROLE_ARN="${aws_iam_role.sns_delivery_role.arn}"

retry_cmd() {
  local cmd="$1"
  local attempts=5
  local delay=1
  for i in $(seq 1 $attempts); do
    if eval "$cmd"; then
      echo "[ok] command succeeded"
      return 0
    else
      echo "[warn] command failed (attempt $i/$attempts). Retrying in $delay s..."
      sleep $delay
      delay=$((delay * 2))
    fi
  done
  echo "[error] command failed after $attempts attempts"
  return 1
}

retry_cmd "aws sns set-topic-attributes --region \"$REGION\" --topic-arn \"$TOPIC_ARN\" --attribute-name SQSFailureFeedbackRoleArn --attribute-value \"$ROLE_ARN\""
retry_cmd "aws sns set-topic-attributes --region \"$REGION\" --topic-arn \"$TOPIC_ARN\" --attribute-name SQSSuccessFeedbackRoleArn --attribute-value \"$ROLE_ARN\""
retry_cmd "aws sns set-topic-attributes --region \"$REGION\" --topic-arn \"$TOPIC_ARN\" --attribute-name SQSSuccessFeedbackSampleRate --attribute-value \"100\""
retry_cmd "aws sns set-topic-attributes --region \"$REGION\" --topic-arn \"$TOPIC_ARN\" --attribute-name LambdaFailureFeedbackRoleArn --attribute-value \"$ROLE_ARN\""
retry_cmd "aws sns set-topic-attributes --region \"$REGION\" --topic-arn \"$TOPIC_ARN\" --attribute-name LambdaSuccessFeedbackSampleRate --attribute-value \"100\""
EOT
    interpreter = ["/bin/bash", "-c"]
  }

  # Re-run when role or topic changes
  triggers = {
    topic_arn = aws_sns_topic.fanout.arn
    role_arn  = aws_iam_role.sns_delivery_role.arn
  }
}

# Add API endpoint to outputs
locals {
  outputs_for_serverless = merge(local.base_outputs, {
    api_endpoint = aws_apigatewayv2_api.http_api.api_endpoint
  })
}

resource "local_file" "outputs" {
  content  = jsonencode(local.outputs_for_serverless)
  filename = "${path.module}/outputs.json"
}

# CloudWatch Alarms
# Alarm for Lambda Errors > 0 in 1 minute
resource "aws_cloudwatch_metric_alarm" "lambda_errors_alarm" {
  alarm_name          = "lambda-publisher-errors-${random_id.suffix.hex}"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions = {
    FunctionName = aws_lambda_function.publisher.function_name
  }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_description   = "Alarm when Lambda publisher has errors"
}

# Alarm for SQS ApproximateNumberOfMessagesVisible > 0
resource "aws_cloudwatch_metric_alarm" "sqs_visible_messages_alarm" {
  alarm_name          = "sqs-visible-${random_id.suffix.hex}"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions = {
    QueueName = aws_sqs_queue.queues[0].name
  }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_description   = "Alarm when messages are visible in queue 1"
}

# SNS alarm: NumberOfNotificationsFailed > 0
resource "aws_cloudwatch_metric_alarm" "sns_notifications_failed_alarm" {
  alarm_name          = "sns-notifications-failed-${random_id.suffix.hex}"
  namespace           = "AWS/SNS"
  metric_name         = "NumberOfNotificationsFailed"
  dimensions = {
    TopicName = aws_sns_topic.fanout.name
  }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_description   = "Alarm when SNS has failed notifications"
}

# Per-queue alarms: ApproximateNumberOfMessagesVisible and ApproximateAgeOfOldestMessage
resource "aws_cloudwatch_metric_alarm" "sqs_visible_messages_per_queue" {
  for_each = { for idx, q in aws_sqs_queue.queues : idx => q }

  alarm_name          = "sqs-visible-${random_id.suffix.hex}-${each.key}"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions = {
    QueueName = each.value.name
  }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_description   = "Alarm when messages are visible in queue ${each.key}"
}

resource "aws_cloudwatch_metric_alarm" "sqs_age_oldest_per_queue" {
  for_each = { for idx, q in aws_sqs_queue.queues : idx => q }

  alarm_name          = "sqs-oldest-age-${random_id.suffix.hex}-${each.key}"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateAgeOfOldestMessage"
  dimensions = {
    QueueName = each.value.name
  }
  statistic           = "Maximum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 300
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_description   = "Alarm when oldest message in queue ${each.key} is older than 5 minutes"
}

# ---------------------------
# Dead-letter queue alarms
# ---------------------------

# Alarm when any message lands in a DLQ (means a consumer failed 3 times)
resource "aws_cloudwatch_metric_alarm" "dlq_messages_visible" {
  for_each = { for idx, q in aws_sqs_queue.dlqs : idx => q }

  alarm_name          = "dlq-messages-visible-${random_id.suffix.hex}-${each.key}"
  namespace           = "AWS/SQS"
  metric_name         = "ApproximateNumberOfMessagesVisible"
  dimensions = {
    QueueName = each.value.name
  }
  statistic           = "Sum"
  period              = 60
  evaluation_periods  = 1
  threshold           = 1
  comparison_operator = "GreaterThanOrEqualToThreshold"
  alarm_description   = "DLQ ${each.value.name} has messages — consumer failed after 3 retries"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
}

# Grant Lambda permission to receive/delete from DLQs (for manual redriving)
resource "aws_iam_policy" "lambda_dlq_policy" {
  name = "lambda-dlq-${random_id.suffix.hex}"
  policy = jsonencode({
    Version = "2012-10-17",
    Statement = [
      {
        Effect = "Allow",
        Action = [
          "sqs:ReceiveMessage",
          "sqs:DeleteMessage",
          "sqs:GetQueueAttributes",
          "sqs:ChangeMessageVisibility",
          "sqs:SendMessage"
        ],
        Resource = [for q in aws_sqs_queue.dlqs : q.arn]
      }
    ]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_dlq_attach" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = aws_iam_policy.lambda_dlq_policy.arn
}


