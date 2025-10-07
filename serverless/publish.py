import json
import sys
from pathlib import Path

import boto3


def load_outputs():
    p = Path(__file__).resolve().parent.parent / 'terraform' / 'outputs.json'
    if not p.exists():
        print(f"outputs.json not found at {p}")
        sys.exit(1)
    return json.loads(p.read_text())


def publish(message: str):
    outputs = load_outputs()
    sns_arn = outputs.get('sns_topic_arn')
    if not sns_arn:
        print('sns_topic_arn missing in outputs.json')
        sys.exit(1)

    client = boto3.client('sns')
    resp = client.publish(TopicArn=sns_arn, Message=message)
    print('Published message, MessageId:', resp.get('MessageId'))


if __name__ == '__main__':
    msg = ' '.join(sys.argv[1:]) or 'Hello from publish.py'
    publish(msg)
