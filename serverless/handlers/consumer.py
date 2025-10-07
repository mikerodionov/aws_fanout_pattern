import json
import logging

logger = logging.getLogger()
logger.setLevel(logging.INFO)

def handler(event, context):
    # event contains Records from SQS
    logger.info("Received event with %d records", len(event.get('Records', [])))
    for r in event.get('Records', []):
        logger.info("MessageId=%s Body=%s", r.get('messageId'), r.get('body'))

    return {
        'statusCode': 200,
        'body': json.dumps({'processed': len(event.get('Records', []))})
    }
