import os
import json
import logging
import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SNS_TOPIC_ARN = os.getenv('SNS_TOPIC_ARN')


def handler(event, context):
    """API Gateway HTTP API handler — publishes the POST body to SNS.
    DynamoDB persistence is handled by each consumer after successful processing.
    """
    body = event.get('body')
    if not body:
        return {'statusCode': 400, 'body': json.dumps({'error': 'missing body'})}

    topic_arn = SNS_TOPIC_ARN
    if not topic_arn:
        logger.error('SNS_TOPIC_ARN not configured')
        return {'statusCode': 500, 'body': json.dumps({'error': 'SNS_TOPIC_ARN not configured'})}

    try:
        region = topic_arn.split(':')[3] if topic_arn else None
        client = boto3.client('sns', region_name=region)
        resp = client.publish(TopicArn=topic_arn, Message=body)
        logger.info('Published to SNS, MessageId=%s', resp.get('MessageId'))
        return {'statusCode': 200, 'body': json.dumps({'messageId': resp.get('MessageId')})}
    except Exception as e:
        logger.exception('publish failed')
        return {'statusCode': 500, 'body': json.dumps({'error': str(e)})}
