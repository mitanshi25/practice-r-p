output "ingestion_bucket_name" {
  description = "Bucket where CSV files are uploaded before publishing"
  value       = aws_s3_bucket.ingestion.bucket
}

output "distribution_bucket_name" {
  description = "Bucket where validated CSV files are copied on publish"
  value       = aws_s3_bucket.distribution.bucket
}

output "table_name" {
  description = "DynamoDB table holding published items"
  value       = aws_dynamodb_table.items.name
}

output "publish_file_lambda_name" {
  description = "Internal Lambda, invoked from the console"
  value       = aws_lambda_function.publish_file.function_name
}

output "publish_file_lambda_arn" {
  description = "ARN of the publish-file Lambda"
  value       = aws_lambda_function.publish_file.arn
}

output "get_item_lambda_name" {
  description = "Public Lambda behind API Gateway"
  value       = aws_lambda_function.get_item.function_name
}

output "api_url" {
  description = "Base URL of the public API, e.g. <api_url>/items/1"
  value       = aws_apigatewayv2_api.main.api_endpoint
}
