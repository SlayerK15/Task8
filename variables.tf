variable "aws_region" {
  description = "AWS Region"
  type        = string
  default     = "us-east-1"
}

variable "ecs_cluster_name" {
  description = "ECS Cluster Name"
  type        = string
  default     = "medusa-cluster"
}

variable "ecs_service_name" {
  description = "ECS Service Name"
  type        = string
  default     = "medusa-service"
}

variable "image_uri" {
  description = "The URI of the Docker image to deploy"
  type        = string
}
