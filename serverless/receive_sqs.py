import json
import sys
import time
from pathlib import Path

import boto3


def load_outputs():
    p = Path(__file__).resolve().parent.parent / 'terraform' / 'outputs.json'
    if not p.exists():
        print(f"outputs.json not found at {p}")
        sys.exit(1)
    return json.loads(p.read_text())


def receive_and_delete(queue_url: str, client):
    resp = client.receive_message(QueueUrl=queue_url, MaxNumberOfMessages=10, WaitTimeSeconds=5)
    msgs = resp.get('Messages', [])
    if not msgs:
        print(f'No messages in {queue_url}')
        return
    for m in msgs:
        print('Received from', queue_url)
        print(' MessageId:', m.get('MessageId'))
        print(' Body:', m.get('Body'))
        # delete
        client.delete_message(QueueUrl=queue_url, ReceiptHandle=m['ReceiptHandle'])
        print(' Deleted message')


def main():
    outputs = load_outputs()
    queues = outputs.get('queues', [])
    if not queues:
        print('No queues found in outputs.json')
        return

    # derive region from queue url (https://sqs.<region>.amazonaws.com/...) - fallback to us-east-1
    sample_url = queues[0].get('url', '')
    region = 'us-east-1'
    try:
        if sample_url:
            region = sample_url.split('.')[1]
    except Exception:
        region = 'us-east-1'
    client = boto3.client('sqs', region_name=region)
    for q in queues:
        url = q.get('url')
        if url:
            url = url.strip()
            receive_and_delete(url, client)


if __name__ == '__main__':
    main()
