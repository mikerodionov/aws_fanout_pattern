import json
import boto3
import time
import uuid

logs = boto3.client('logs')

def ensure_log_stream(log_group, stream_name):
    try:
        logs.create_log_stream(logGroupName=log_group, logStreamName=stream_name)
    except logs.exceptions.ResourceAlreadyExistsException:
        pass
    except Exception:
        # ignore other errors and let put_log_events handle them
        pass

def put_log_event(log_group, message):
    stream = f"logger-{int(time.time()*1000)}-{uuid.uuid4().hex[:6]}"
    ensure_log_stream(log_group, stream)
    ts = int(time.time()*1000)
    try:
        logs.put_log_events(logGroupName=log_group, logStreamName=stream,
                            logEvents=[{'timestamp': ts, 'message': message}])
    except logs.exceptions.InvalidSequenceTokenException:
        # fetch sequence token and retry
        streams = logs.describe_log_streams(logGroupName=log_group, logStreamNamePrefix=stream)
        token = None
        if 'logStreams' in streams and len(streams['logStreams']) > 0:
            token = streams['logStreams'][0].get('uploadSequenceToken')
        if token:
            logs.put_log_events(logGroupName=log_group, logStreamName=stream,
                                logEvents=[{'timestamp': ts, 'message': message}], sequenceToken=token)
    except Exception as e:
        # best-effort: ignore to avoid failing the consumer
        print(f"Failed to put log event to {log_group}: {e}")


def handler(event, context):
    # Handle SQS and SNS events and write entries into the corresponding CloudWatch log groups
    try:
        if 'Records' in event:
            for r in event['Records']:
                # SQS event
                if r.get('eventSource') == 'aws:sqs':
                    body = r.get('body')
                    arn = r.get('eventSourceARN', '')
                    qname = arn.split(':')[-1] if arn else 'unknown-sqs'
                    log_group = f"/aws/sqs/{qname}"
                    put_log_event(log_group, json.dumps({'type': 'sqs', 'body': body}))
                # SNS event delivered to Lambda
                elif 'Sns' in r:
                    sns = r['Sns']
                    msg = sns.get('Message')
                    topic_arn = sns.get('TopicArn', '')
                    tname = topic_arn.split(':')[-1] if topic_arn else 'unknown-sns'
                    log_group = f"/aws/sns/{tname}"
                    put_log_event(log_group, json.dumps({'type': 'sns', 'message': msg}))
                else:
                    # unknown record type
                    put_log_event('/aws/sqs/unknown', json.dumps(r))
        else:
            # direct invocation or other event
            put_log_event('/aws/sns/unknown', json.dumps(event))
    except Exception as e:
        print('Error in logger handler:', e)

    return {'status': 'ok'}
