import os
import json
from pathlib import Path


def load_outputs():
    p = Path(__file__).resolve().parent.parent / 'terraform' / 'outputs.json'
    if not p.exists():
        raise SystemExit(f"outputs.json not found at {p}")
    return json.loads(p.read_text())


def main():
    outputs = load_outputs()
    arn = outputs.get('sns_topic_arn')
    if not arn:
        raise SystemExit('sns_topic_arn missing in outputs.json')

    # Set env var before importing handler (it reads at import time)
    os.environ['SNS_TOPIC_ARN'] = arn

    # import and call handler
    from handlers.publisher import handler

    event = {
        'body': json.dumps({'test': 'from test_publisher_local'})
    }

    resp = handler(event, None)
    print('publisher handler response:', resp)


if __name__ == '__main__':
    main()
