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
