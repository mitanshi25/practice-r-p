# publish-file + get-item

Two Python 3.12 Lambdas, deployed by GitHub Actions. AWS resources are created manually.

- `publish-file` (internal, run from the Lambda console): validates a CSV in the ingestion bucket. With `dryRun: false` it also writes the rows to DynamoDB and copies the file to the distribution bucket.
- `get-item` (public, via API Gateway): `GET /items/{id}`.

## Manual AWS setup

Pick a region and use it everywhere.

1. **S3:** create `<proj>-ingestion` and `<proj>-distribution`, both private (block public access on).
2. **DynamoDB:** table `items`, partition key `id` (String), on-demand.
3. **IAM roles for Lambda** (trusted entity: Lambda):
   - `publish-file-role`: `AWSLambdaBasicExecutionRole`, plus an inline policy with `s3:GetObject` on the ingestion bucket, `s3:PutObject` on the distribution bucket, and `dynamodb:BatchWriteItem` and `dynamodb:PutItem` on the table.
   - `get-item-role`: `AWSLambdaBasicExecutionRole`, plus `dynamodb:GetItem` on the table.
4. **Lambdas** (Python 3.12, handler `handler.lambda_handler`):
   - `publish-file` with `publish-file-role`, timeout 60s, memory 256MB.
   - `get-item` with `get-item-role`.
   - Environment variables:
     - `publish-file`: `TABLE_NAME=items`, `INGESTION_BUCKET`, `DISTRIBUTION_BUCKET`.
     - `get-item`: `TABLE_NAME=items`.
   - Do NOT add a function URL or API route to `publish-file`.
5. **API Gateway (HTTP API):** route `GET /items/{id}` with a Lambda integration to `get-item`. Keep the `$default` stage with auto-deploy. Note the invoke URL.
6. **GitHub OIDC:**
   - IAM → Identity providers → add `token.actions.githubusercontent.com`, audience `sts.amazonaws.com`.
   - Create role `gha-deploy` (web identity). Trust it for `repo:<owner>/<repo>:ref:refs/heads/main`.
   - Give it `lambda:UpdateFunctionCode` on the two functions.
   - In the GitHub repo → Settings → Variables, add `AWS_DEPLOY_ROLE_ARN` and `AWS_REGION`.

## Adding dependencies (Lambda layer)

1. Add the package to `layers/deps/requirements.txt` (pinned, e.g. `requests==2.32.3`). Skip `boto3`, the runtime has it.
2. Import it in the handler as usual.
3. Push to `main`. The workflow installs the packages for Linux/x86_64/Python 3.12 into `python/`, zips them, publishes a new version of the `shared-deps` layer and attaches it to both functions.

One-time: add these to the `gha-deploy` role policy, and keep the Lambdas on x86_64 (the default):
`lambda:PublishLayerVersion` on `arn:aws:lambda:<region>:<account>:layer:shared-deps`, and `lambda:UpdateFunctionConfiguration` and `lambda:GetFunction` on the two functions.
(`GetFunction` is needed so the workflow can wait for updates to finish.) If you switch to arm64, change the platform to `manylinux2014_aarch64` and the architecture in the workflow.

Manual alternative: run the same `pip install ... -t build/python` and `zip` locally, then upload it under Lambda → Layers → Create layer.

## Using it

Upload a CSV (header `id,title,description`, see `sample/items.csv`) to the ingestion bucket. In the Lambda console, Test `publish-file` with:

```json
{ "fileKey": "items.csv", "author": "meet", "dryRun": true }
```

Set `dryRun` to `false` to publish. Result statuses: `INVALID`, `DRY_RUN_OK`, `PUBLISHED`.

Then: `curl <invoke-url>/items/1`

## Deploy

Push to `main`. The workflow zips both Lambdas and runs `update-function-code`.
