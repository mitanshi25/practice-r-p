import json
import os
from decimal import Decimal

import boto3

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])


def _default(o):
    if isinstance(o, Decimal):
        return int(o) if o == o.to_integral_value() else float(o)
    raise TypeError


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"Content-Type": "application/json"},
        "body": json.dumps(body, default=_default),
    }


def lambda_handler(event, context):
    item_id = (event.get("pathParameters") or {}).get("id")
    if not item_id:
        return _response(400, {"message": "id is required"})

    item = table.get_item(Key={"id": item_id}).get("Item")
    if not item:
        return _response(404, {"message": "not found"})
    return _response(200, item)
