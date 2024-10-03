# Variables
variable "aws_region" {
  default = "us-east-1"
}

variable "ecs_cluster_name" {
  default = "medusa-cluster"
}

variable "ecs_service_name" {
  default = "medusa-service"
}

variable "image_uri" {
  default = "your-image-uri"
}
