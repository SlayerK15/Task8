provider "aws" {
  region = "us-east-1"
}

# ECS Cluster
resource "aws_ecs_cluster" "medusa_cluster" {
  name = "medusa-cluster"
}

# ECS Task Definition (assuming you already have this in place)
resource "aws_ecs_task_definition" "medusa_task" {
  family                   = "medusa-task"
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  execution_role_arn       = aws_iam_role.ecs_task_execution_role.arn
  container_definitions    = jsonencode([
    {
      name      = "medusa-app"
      image     = "202533508516.dkr.ecr.us-east-1.amazonaws.com/medusa-app"
      cpu       = 256
      memory    = 512
      essential = true
      portMappings = [{
        containerPort = 9000
        hostPort      = 9000
      }]
    }
  ])
  cpu                     = "256"
  memory                  = "512"
  requires_compatibilities = ["FARGATE"]
  network_mode            = "awsvpc"
}

# ECS Service
resource "aws_ecs_service" "medusa_service" {
  name            = "medusa-service"
  cluster         = aws_ecs_cluster.medusa_cluster.id
  task_definition = aws_ecs_task_definition.medusa_task.arn
  desired_count   = 1
  launch_type     = "FARGATE"

  network_configuration {
    subnets          = var.subnets
    security_groups  = [aws_security_group.allow_all.id]
    assign_public_ip = true
  }

  load_balancer {
    target_group_arn = aws_lb_target_group.lb_target_group.arn
    container_name   = "medusa-app"
    container_port   = 9000
  }
}

# IAM Role for ECS Autoscaling
resource "aws_iam_role" "ecs_autoscaling_role" {
  name = "ecsAutoscalingRole"

  assume_role_policy = jsonencode({
    "Version": "2012-10-17",
    "Statement": [{
      "Action": "sts:AssumeRole",
      "Principal": {
        "Service": "application-autoscaling.amazonaws.com"
      },
      "Effect": "Allow",
      "Sid": ""
    }]
  })
}

resource "aws_iam_role_policy_attachment" "ecs_autoscaling_policy" {
  role       = aws_iam_role.ecs_autoscaling_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEC2ContainerServiceAutoscaleRole"
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
  service_namespace  = aws_appautoscaling_target.ecs.service_namespace

  step_scaling_policy_configuration {
    adjustment_type = "ChangeInCapacity"
    cooldown        = 300

    step_adjustment {
      scaling_adjustment           = -1
      metric_interval_upper_bound  = 0
    }
  }
}
