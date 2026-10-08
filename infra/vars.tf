variable "aws_region" {
  description = "AWS region for all resources"
  type        = string
  default     = "ap-south-1"
}

variable "project" {
  description = "Short project name, used as a prefix in resource names"
  type        = string
  default     = "practice-e2e"
}
