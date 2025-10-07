import os
import json
import logging
from typing import Any, Dict, Optional

import boto3

logger = logging.getLogger()
logger.setLevel(logging.INFO)


def _region_from_arn(arn: str) -> Optional[str]:
    # ARN format: arn:partition:service:region:account-id:resource
    try:
        parts = arn.split(":")
        if len(parts) >= 4:
            return parts[3]
    except Exception:
        return None
    return None


def handler(event: Dict[str, Any], context):
    """HTTP API handler that publishes the POST body to SNS.

    Expects a JSON body or plain text. Returns 400 on missing body or missing SNS topic.
    """
    sns_arn = os.getenv('SNS_TOPIC_ARN')
    if not sns_arn:
        logger.error('SNS_TOPIC_ARN not set')
        return {'statusCode': 500, 'body': json.dumps({'error': 'SNS_TOPIC_ARN not configured'})}

    # For HTTP API, body might be in event['body']
    body = event.get('body')
    if body is None:
        return {'statusCode': 400, 'body': json.dumps({'error': 'Missing body'})}

    message = body
    # Ensure we create client with correct region derived from ARN (avoids InvalidParameter)
    region = _region_from_arn(sns_arn) or os.getenv('AWS_REGION') or 'us-east-1'
    try:
        client = boto3.client('sns', region_name=region)
        resp = client.publish(TopicArn=sns_arn, Message=message)
        logger.info('Published message to SNS, MessageId=%s', resp.get('MessageId'))
        return {'statusCode': 200, 'body': json.dumps({'messageId': resp.get('MessageId')})}
    except Exception as e:
        logger.exception('Failed to publish to SNS')
        return {'statusCode': 500, 'body': json.dumps({'error': str(e)})}
