import json

def handler(event, context):
    print("Received event:", json.dumps(event))
    raise Exception("Intentional failure for delivery logging test")
