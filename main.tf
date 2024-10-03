# Provider Configuration
provider "aws" {
  region = "us-east-1"  # Replace with your desired AWS region
}

# VPC Configuration
resource "aws_vpc" "main" {
  cidr_block           = "10.0.0.0/16"
  enable_dns_support   = true
  enable_dns_hostnames = true
}

# Data source for Availability Zones
data "aws_availability_zones" "available" {}

# Subnets Configuration
resource "aws_subnet" "public" {
  count                   = 2
  vpc_id                  = aws_vpc.main.id
  cidr_block              = cidrsubnet(aws_vpc.main.cidr_block, 8, count.index)
  availability_zone       = data.aws_availability_zones.available.names[count.index]
  map_public_ip_on_launch = true
}

# Internet Gateway
resource "aws_internet_gateway" "igw" {
  vpc_id = aws_vpc.main.id
}

# Route Table Configuration
resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id

  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.igw.id
  }
}

# Route Table Associations
resource "aws_route_table_association" "public" {
  count          = 2
  subnet_id      = aws_subnet.public[count.index].id
  route_table_id = aws_route_table.public.id
}

# Security Group for ECS Service
resource "aws_security_group" "ecs_service" {
  name        = "ecs_service_sg"
  description = "Allow HTTP traffic"
  vpc_id      = aws_vpc.main.id

  ingress {
    from_port   = 9000
    to_port     = 9000
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

# ECS Cluster
resource "aws_ecs_cluster" "medusa_cluster" {
  name = "medusa-cluster"  # Replace with your ECS cluster name if different
}

# IAM Role for ECS Task Execution
resource "aws_iam_role" "ecs_task_execution_role" {
  name = "ecsTaskExecutionRole"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "ecs-tasks.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })
}

# Attach the AWS managed policy for ECS Task Execution
resource "aws_iam_role_policy_attachment" "ecs_task_execution_role_policy" {
  role       = aws_iam_role.ecs_task_execution_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

# ECS Task Definition
resource "aws_ecs_task_definition" "medusa_task" {
  family                   = "medusa-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = "1024"
  memory                   = "2048"
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  task_role_arn            = aws_iam_role.ecs_task_execution_role.arn

  container_definitions = jsonencode([
    {
      name      = "postgres-container"
      image     = "postgres:13-alpine"
      essential = true
      memory    = 512
      cpu       = 256
      environment = [
        { name  = "POSTGRES_USER", value = "medusa_user" },
        { name  = "POSTGRES_PASSWORD", value = "medusa_password" },
        { name  = "POSTGRES_DB", value = "medusa_db" }
      ]
      portMappings = [{
        containerPort = 5432
        hostPort      = 5432
        protocol      = "tcp"
      }]
    },
    {
      name      = "medusa-container"
      image     = "your-image-uri"  # Replace with your Docker image URI
      essential = true
      memory    = 1536
      cpu       = 768
      environment = [
        { name  = "DATABASE_URL", value = "postgres://medusa_user:medusa_password@localhost:5432/medusa_db" },
        { name  = "NODE_ENV", value = "production" }
      ]
      portMappings = [{
        containerPort = 9000
        hostPort      = 9000
        protocol      = "tcp"
      }]
      dependsOn = [{
        containerName = "postgres-container"
        condition     = "START"
      }]
    }
  ])
}

# ECS Service using Fargate Spot
resource "aws_ecs_service" "medusa_service" {
  name            = "medusa-service"  # Replace with your ECS service name if different
  cluster         = aws_ecs_cluster.medusa_cluster.id
  task_definition = aws_ecs_task_definition.medusa_task.arn
  desired_count   = 1

  network_configuration {
    subnets         = aws_subnet.public[*].id
    security_groups = [aws_security_group.ecs_service.id]
    assign_public_ip = true
  }

  capacity_provider_strategy {
    capacity_provider = "FARGATE_SPOT"
    weight            = 1
  }
}

# Autoscaling Target
resource "aws_appautoscaling_target" "ecs" {
  max_capacity       = 3
  min_capacity       = 1
  resource_id        = "service/${aws_ecs_cluster.medusa_cluster.name}/${aws_ecs_service.medusa_service.name}"
  scalable_dimension = "ecs:service:DesiredCount"
  service_namespace  = "ecs"
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
}

# High CPU Utilization Alarm (Scale Up)
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  alarm_name                = "MedusaCPUHigh"
  comparison_operator       = "GreaterThanThreshold"
  evaluation_periods        = 2
  metric_name               = "CPUUtilization"
  namespace                 = "AWS/ECS"
  period                    = 60
  statistic                 = "Average"
  threshold                 = 70
  alarm_description         = "Alarm when CPU exceeds 70%"

  dimensions = {
    ClusterName = aws_ecs_cluster.medusa_cluster.name
    ServiceName = aws_ecs_service.medusa_service.name
  }

  alarm_actions = [aws_appautoscaling_policy.cpu_scale_up.arn]
}

# Low CPU Utilization Alarm (Scale Down)
resource "aws_cloudwatch_metric_alarm" "cpu_low" {
  alarm_name                = "MedusaCPULow"
  comparison_operator       = "LessThanThreshold"
  evaluation_periods        = 2
  metric_name               = "CPUUtilization"
  namespace                 = "AWS/ECS"
  period                    = 60
  statistic                 = "Average"
  threshold                 = 30
  alarm_description         = "Alarm when CPU falls below 30%"

  dimensions = {
    ClusterName = aws_ecs_cluster.medusa_cluster.name
    ServiceName = aws_ecs_service.medusa_service.name
  }

  alarm_actions = [aws_appautoscaling_policy.cpu_scale_down.arn]
}

# Output (optional)
output "ecs_service_name" {
  value = aws_ecs_service.medusa_service.name
}
