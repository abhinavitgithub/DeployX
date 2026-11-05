# DeployX — AWS Monitoring Architecture (CloudWatch Logs & Metrics)
# Configures centralized logging, instance health metrics, and automated threshold alarms.

# ------------------------------------------------------------------------------
# 1. Centralized CloudWatch Log Group
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_log_group" "deployx" {
  name              = "/deployx/${var.environment}"
  retention_in_days = var.cloudwatch_log_retention_days

  tags = {
    Name    = "${local.name_prefix}-log-group"
    Service = "Logging"
  }
}

# ------------------------------------------------------------------------------
# 2. SNS Alert Topic (Optional / Configurable)
# ------------------------------------------------------------------------------
resource "aws_sns_topic" "alerts" {
  count = var.enable_cloudwatch_alarms && var.alarm_sns_topic_arn == "" ? 1 : 0
  name  = "${local.name_prefix}-alerts-topic"

  tags = {
    Name = "${local.name_prefix}-alerts-topic"
  }
}

locals {
  target_alarm_actions = var.enable_cloudwatch_alarms ? (
    var.alarm_sns_topic_arn != "" ? [var.alarm_sns_topic_arn] : (
      length(aws_sns_topic.alerts) > 0 ? [aws_sns_topic.alerts[0].arn] : []
    )
  ) : []
}

# ------------------------------------------------------------------------------
# 3. High CPU Utilization Metric Alarm
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "cpu_high" {
  count               = var.enable_cloudwatch_alarms ? 1 : 0
  alarm_name          = "${local.name_prefix}-cpu-utilization-high"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "CPUUtilization"
  namespace           = "AWS/EC2"
  period              = 300
  statistic           = "Average"
  threshold           = var.cpu_utilization_threshold
  alarm_description   = "Triggered when DeployX EC2 host CPU exceeds ${var.cpu_utilization_threshold}% over 10 minutes."
  alarm_actions       = local.target_alarm_actions
  ok_actions          = local.target_alarm_actions

  dimensions = {
    InstanceId = aws_instance.deployx.id
  }

  tags = {
    Name = "${local.name_prefix}-cpu-alarm"
  }
}

# ------------------------------------------------------------------------------
# 4. EC2 Instance Status Check Failure Alarm
# ------------------------------------------------------------------------------
resource "aws_cloudwatch_metric_alarm" "status_check" {
  count               = var.enable_cloudwatch_alarms ? 1 : 0
  alarm_name          = "${local.name_prefix}-instance-status-check-failed"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "StatusCheckFailed"
  namespace           = "AWS/EC2"
  period              = 60
  statistic           = "Maximum"
  threshold           = 0
  alarm_description   = "Triggered when DeployX EC2 host fails hypervisor or system status health checks."
  alarm_actions       = local.target_alarm_actions
  ok_actions          = local.target_alarm_actions

  dimensions = {
    InstanceId = aws_instance.deployx.id
  }

  tags = {
    Name = "${local.name_prefix}-status-alarm"
  }
}
