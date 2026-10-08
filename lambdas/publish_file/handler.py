import csv
import io
import os
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

REQUIRED_COLUMNS = ["id", "title", "description"]

s3 = boto3.client("s3")
dynamodb = boto3.resource("dynamodb")


def lambda_handler(event, context):
    file_key = (event.get("fileKey") or "").strip()
    author = (event.get("author") or "").strip()
    dry_run = event.get("dryRun", True)

    if not file_key or not author:
        return {"status": "INVALID", "errors": ["fileKey and author are required"]}
    if not isinstance(dry_run, bool):
        return {"status": "INVALID", "errors": ["dryRun must be true or false"]}

    ingestion_bucket = os.environ["INGESTION_BUCKET"]
    distribution_bucket = os.environ["DISTRIBUTION_BUCKET"]
    table = dynamodb.Table(os.environ["TABLE_NAME"])

    try:
        body = s3.get_object(Bucket=ingestion_bucket, Key=file_key)["Body"].read()
    except ClientError as e:
        if e.response["Error"]["Code"] == "NoSuchKey":
            return {"status": "INVALID", "errors": [f"{file_key} not found in {ingestion_bucket}"]}
        raise

    rows, errors = validate(body.decode("utf-8-sig"))
    if errors:
        return {"status": "INVALID", "errors": errors}

    if dry_run:
        return {"status": "DRY_RUN_OK", "rows": len(rows)}

    published_at = datetime.now(timezone.utc).isoformat()
    with table.batch_writer() as batch:
        for row in rows:
            batch.put_item(
                Item={
                    **row,
                    "author": author,
                    "sourceFileKey": file_key,
                    "publishedAt": published_at,
                }
            )

    distribution_key = f"published/{file_key}"
    s3.copy_object(
        Bucket=distribution_bucket,
        Key=distribution_key,
        CopySource={"Bucket": ingestion_bucket, "Key": file_key},
    )

    return {"status": "PUBLISHED", "rows": len(rows), "distributionKey": distribution_key}


def validate(text):
    reader = csv.DictReader(io.StringIO(text))
    headers = reader.fieldnames or []
    missing = [c for c in REQUIRED_COLUMNS if c not in headers]
    if missing:
        return [], [f"missing required columns: {', '.join(missing)}"]

    rows, errors, seen_ids = [], [], set()
    for line_no, row in enumerate(reader, start=2):
        row = {k: (v or "").strip() for k, v in row.items() if k}
        for col in REQUIRED_COLUMNS:
            if not row.get(col):
                errors.append(f"row {line_no}: '{col}' is empty")
        row_id = row.get("id")
        if row_id:
            if row_id in seen_ids:
                errors.append(f"row {line_no}: duplicate id '{row_id}'")
            seen_ids.add(row_id)
        rows.append(row)

    if not rows:
        errors.append("file has no data rows")
    return rows, errors
