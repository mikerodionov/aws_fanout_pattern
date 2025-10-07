import os
import json
import logging
import boto3
import uuid
import time

logger = logging.getLogger()
logger.setLevel(logging.INFO)

SNS_TOPIC_ARN = os.getenv('SNS_TOPIC_ARN')
DDB_TABLE_NAME = os.getenv('DDB_TABLE_NAME')


def _put_to_dynamodb(table_name, item, region=None):
    if not table_name:
        logger.warning('No DDB table configured')
        return
    client = boto3.client('dynamodb', region_name=region)
    # item is a dict of string values
    ddb_item = {k: {'S': str(v)} for k, v in item.items()}
    client.put_item(TableName=table_name, Item=ddb_item)


def handler(event, context):
    # API Gateway HTTP API v2 -> body in event['body']
    body = event.get('body')
    if not body:
        return {'statusCode': 400, 'body': json.dumps({'error': 'missing body'})}

    topic_arn = SNS_TOPIC_ARN
    if not topic_arn:
        logger.error('SNS_TOPIC_ARN not configured')
        return {'statusCode': 500, 'body': json.dumps({'error': 'SNS_TOPIC_ARN not configured'})}

    # prepare record for DynamoDB
    record_id = str(uuid.uuid4())
    ts = int(time.time())
    try:
        # derive region from ARN
        region = topic_arn.split(':')[3] if topic_arn else None

        # write to DynamoDB (best-effort)
        try:
            _put_to_dynamodb(DDB_TABLE_NAME, {'id': record_id, 'timestamp': ts, 'body': body}, region=region)
        except Exception:
            logger.exception('Failed to write to DynamoDB')

        # publish to SNS
        client = boto3.client('sns', region_name=region)
        resp = client.publish(TopicArn=topic_arn, Message=body)
        return {'statusCode': 200, 'body': json.dumps({'messageId': resp.get('MessageId'), 'ddb_id': record_id})}
    except Exception as e:
        logger.exception('publish failed')
        return {'statusCode': 500, 'body': json.dumps({'error': str(e)})}
