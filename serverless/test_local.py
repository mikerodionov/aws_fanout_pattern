from handlers.consumer import handler
import json


def make_sqs_event(bodies):
    records = []
    for i, b in enumerate(bodies, start=1):
        records.append({
            'messageId': f'msg-{i}',
            'body': b,
            'attributes': {},
        })
    return {'Records': records}


def main():
    event = make_sqs_event([
        json.dumps({'hello': 'world'}),
        'plain-text-message'
    ])

    result = handler(event, None)
    print('handler result:', result)


if __name__ == '__main__':
    main()
