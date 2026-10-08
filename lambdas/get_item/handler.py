import base64
import json
import os
from decimal import Decimal

import boto3

table = boto3.resource("dynamodb").Table(os.environ["TABLE_NAME"])

VALIDATED_FIELDS = ["title", "description"]


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
    route = event.get("routeKey")
    if route == "GET /items/{id}":
        return get_item(event)
    if route == "POST /validation":
        return validate_item(event)
    return _response(404, {"message": "route not found"})


def get_item(event):
    item_id = (event.get("pathParameters") or {}).get("id")
    if not item_id:
        return _response(400, {"message": "id is required"})

    item = table.get_item(Key={"id": item_id}).get("Item")
    if not item:
        return _response(404, {"message": "not found"})
    return _response(200, item)


def validate_item(event):
    raw = event.get("body") or ""
    if event.get("isBase64Encoded"):
        raw = base64.b64decode(raw).decode("utf-8")
    try:
        body = json.loads(raw)
    except ValueError:
        return _response(400, {"message": "body must be valid JSON"})
    if not isinstance(body, dict):
        return _response(400, {"message": "body must be a JSON object"})

    errors = [
        f"'{field}' is required and must be a non-empty string"
        for field in ["id", *VALIDATED_FIELDS]
        if not isinstance(body.get(field), str) or not body[field].strip()
    ]
    if errors:
        return _response(400, {"message": "invalid request", "errors": errors})

    item = table.get_item(Key={"id": body["id"]}).get("Item")
    if not item:
        return _response(404, {"message": "not found"})

    mismatches = [
        {"field": field, "expected": item.get(field), "received": body[field]}
        for field in VALIDATED_FIELDS
        if item.get(field) != body[field]
    ]
    if mismatches:
        return _response(200, {"valid": False, "mismatches": mismatches})
    return _response(200, {"valid": True})
