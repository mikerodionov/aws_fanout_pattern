output "sns_topic_arn" {
  value = aws_sns_topic.fanout.arn
}

output "queue_arns" {
  value = [for q in aws_sqs_queue.queues : q.arn]
}

output "queue_urls" {
  value = [for q in aws_sqs_queue.queues : q.id]
}

output "dlq_arns" {
  value = [for q in aws_sqs_queue.dlqs : q.arn]
}

output "dlq_urls" {
  value = [for q in aws_sqs_queue.dlqs : q.id]
}
