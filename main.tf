# Provider Configuration
provider "aws" {
  region = var.aws_region
}

# Data Sources
data "aws_caller_identity" "current" {}

# Variables Definition
variable "aws_region" {
  description = "The AWS region to deploy resources in."
  default     = "us-east-1"
}

variable "vpc_cidr" {
  description = "CIDR block for the VPC."
  default     = "10.0.0.0/16"
}

variable "az_count" {
  description = "Number of availability zones to use."
  default     = 2
}

variable "ecs_cluster_name" {
  description = "Name of the ECS cluster."
  default     = "medusa-cluster"
}

variable "ecr_repository_name" {
  description = "Name of the ECR repository."
  default     = "medusa-app-repo"
}

variable "ecs_service_name" {
  description = "Name of the ECS service."
  default     = "medusa-service"
}

variable "ecs_task_family" {
  description = "Family name of the ECS task definition."
  default     = "medusa-task"
}

variable "container_port" {
  description = "Port on which the Medusa container listens."
  default     = 9000
}

variable "postgres_container_port" {
  description = "Port on which the PostgreSQL container listens."
  default     = 5432
}

variable "fargate_cpu" {
  description = "CPU units for Fargate tasks."
  default     = "1024"
}

variable "fargate_memory" {
  description = "Memory in MiB for Fargate tasks."
  default     = "2048"
}

variable "desired_count" {
  description = "Desired number of ECS service instances."
  default     = 1
}

variable "min_capacity" {
  description = "Minimum number of ECS tasks."
  default     = 1
}

variable "max_capacity" {
  description = "Maximum number of ECS tasks."
  default     = 3
}

variable "cpu_scale_up_threshold" {
  description = "CPU utilization percentage to scale up."
  default     = 70
}

variable "cpu_scale_down_threshold" {
  description = "CPU utilization percentage to scale down."
  default     = 30
}

# VPC Configuration
resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true

  lifecycle {
    prevent_destroy = true
  }
}

# Data source for Availability Zones
data "aws_availability_zones" "available" {}

# Subnets Configuration
resource "aws_subnet" "public" {
  count                   = var.az_count
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true

  lifecycle {
    prevent_destroy = true
  }
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id

  lifecycle {
    prevent_destroy = true
  }
}

# Route Table Configuration
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  count          = var.az_count
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id

  lifecycle {
    prevent_destroy = true
  }
}

# Security Group for ECS Service
resource "aws_security_group" "ecs_service" {
  name        = "ecs_service_sg"
  description = "Allow HTTP traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = var.container_port
    to_port     = var.container_port
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  lifecycle {
    prevent_destroy = true
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "medusa_cluster" {
  name = var.ecs_cluster_name

  lifecycle {
    prevent_destroy = true
  }
}

# ECR Repository Data Source (use existing ECR repository)
data "aws_ecr_repository" "medusa_app_repo" {
  name = var.ecr_repository_name
}

# IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17",
    Statement = [{
      Effect = "Allow",
      Principal = {
        Service = "ecs-tasks.amazonaws.com"
      },
      Action = "sts:AssumeRole"
    }]
  })

  lifecycle {
    prevent_destroy = true
  }
}

# Attach AWS Managed Policy for ECS Task Execution
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"

  lifecycle {
    prevent_destroy = true
  }
}

# CloudWatch Log Group for ECS Tasks
resource "aws_cloudwatch_log_group" "ecs_log_group" {
  name              = "/ecs/${var.ecs_task_family}"
  retention_in_days = 30

  lifecycle {
    prevent_destroy = true
  }
}

# ECS Task Definition
resource "aws_ecs_task_definition" "medusa_task" {
  family                   = var.ecs_task_family
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = var.fargate_cpu
  memory                   = var.fargate_memory
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "postgres"
      hostname  = "postgres"
      image     = "postgres:13-alpine"
      essential = true
      memory    = 512
      cpu       = 256
      environment = [
        { name = "POSTGRES_USER", value = "postgres" },
        { name = "POSTGRES_PASSWORD", value = "postgres" },
        { name = "POSTGRES_DB", value = "medusa_db" }
      ]
      portMappings = [{
        containerPort = var.postgres_container_port
        protocol      = "tcp"
      }]
      healthCheck = {
        command     = ["CMD-SHELL", "pg_isready -U postgres"]
        interval    = 10
        timeout     = 5
        retries     = 5
        startPeriod = 30
      }
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_log_group.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "postgres"
        }
      }
    },
    {
      name      = "medusa"
      hostname  = "medusa"
      image     = "${data.aws_ecr_repository.medusa_app_repo.repository_url}:latest"
      essential = true
      memory    = 1536
      cpu       = 768
      environment = [
        { name = "DATABASE_URL", value = "postgres://postgres:postgres@postgres:${var.postgres_container_port}/medusa_db" },
        { name = "NODE_ENV", value = "production" },
        { name = "MEDUSA_BACKEND_URL", value = "http://localhost:${var.container_port}" },
        { name = "JWT_SECRET", value = "your_jwt_secret" },
        { name = "COOKIE_SECRET", value = "your_cookie_secret" }
        # Add other required environment variables
      ]
      portMappings = [{
        containerPort = var.container_port
        protocol      = "tcp"
      }]
      dependsOn = [{
        containerName = "postgres"
        condition     = "HEALTHY"
      }]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = aws_cloudwatch_log_group.ecs_log_group.name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "medusa"
        }
      }
    }
  ])

  lifecycle {
    prevent_destroy = true
  }
}

# ECS Service using Fargate Spot
resource "aws_ecs_service" "medusa_service" {
  name            = var.ecs_service_name
  cluster         = aws_ecs_cluster.medusa_cluster.id
  task_definition = aws_ecs_task_definition.medusa_task.arn
  desired_count   = var.desired_count

  network_configuration {
    subnets         = aws_subnet.public[*].id
    security_groups = [aws_security_group.ecs_service.id]
    assign_public_ip = true
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }

  lifecycle {
    ignore_changes = [task_definition]
  }
}

# Autoscaling Target
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = var.max_capacity
  min_capacity       = var.min_capacity
  resource_id        = "service/${aws_ecs_cluster.medusa_cluster.name}/${aws_ecs_service.medusa_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"

  lifecycle {
    prevent_destroy = true
  }
}

# Autoscaling Policy (Scale Up)
resource "aws_appautoscaling_policy" "cpu_scale_up" {
  name               = "cpu-scale-up"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  step_scaling_policy_configuration {
    adjustment_type = "ChangeInCapacity"
    cooldown        = 60

    step_adjustment {
      scaling_adjustment          = 1
      metric_interval_lower_bound = 0
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# Autoscaling Policy (Scale Down)
resource "aws_appautoscaling_policy" "cpu_scale_down" {
  name               = "cpu-scale-down"
  policy_type        = "StepScaling"
  resource_id        = aws_appautoscaling_target.ecs.resource_id
  scalable_dimension = aws_appautoscaling_target.ecs.scalable_dimension
  service_namespace  = "ecs"

  step_scaling_policy_configuration {
    adjustment_type = "ChangeInCapacity"
    cooldown        = 300

    step_adjustment {
      scaling_adjustment           = -1
      metric_interval_upper_bound  = 0
    }
  }

  lifecycle {
    prevent_destroy = true
  }
}

# High CPU Utilization Alarm (Scale Up)
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name          = "MedusaCPUHigh"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.cpu_scale_up_threshold
  alarm_description   = "Alarm when CPU exceeds ${var.cpu_scale_up_threshold}%"

  dimensions = {
    ClusterName = aws_ecs_cluster.medusa_cluster.name
    ServiceName = aws_ecs_service.medusa_service.name
  }

  alarm_actions = [aws_appautoscaling_policy.cpu_scale_up.arn]

  lifecycle {
    prevent_destroy = true
  }
}

# Low CPU Utilization Alarm (Scale Down)
resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name          = "MedusaCPULow"
  comparison_operator = "LessThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/ECS"
  period              = 60
  statistic           = "Average"
  threshold           = var.cpu_scale_down_threshold
  alarm_description   = "Alarm when CPU falls below ${var.cpu_scale_down_threshold}%"

  dimensions = {
    ClusterName = aws_ecs_cluster.medusa_cluster.name
    ServiceName = aws_ecs_service.medusa_service.name
  }

  alarm_actions = [aws_appautoscaling_policy.cpu_scale_down.arn]

  lifecycle {
    prevent_destroy = true
  }
}

# Output (optional)
output "ecs_service_name" {
  value = aws_ecs_service.medusa_service.name
}
