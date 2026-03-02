output "cluster_name" {
  description = "ECS cluster name"
  value       = aws_ecs_cluster.this.name
}

output "cluster_arn" {
  description = "ECS cluster ARN"
  value       = aws_ecs_cluster.this.arn
}

output "service_name" {
  description = "ECS service name"
  value       = aws_ecs_service.this.name
}

output "service_arn" {
  description = "ECS service ARN"
  value       = aws_ecs_service.this.id
}

output "task_family" {
  description = "Task definition family"
  value       = aws_ecs_task_definition.this.family
}

output "security_group_id" {
  description = "ECS service security group ID"
  value       = aws_security_group.ecs_service.id
}

output "execution_role_arn" {
  description = "Task execution role ARN"
  value       = local.execution_role_arn
}

output "task_role_arn" {
  description = "Task role ARN"
  value       = local.task_role_arn
}

output "backend_log_group_name" {
  description = "Backend log group"
  value       = aws_cloudwatch_log_group.backend.name
}

output "frontend_log_group_name" {
  description = "Frontend log group"
  value       = aws_cloudwatch_log_group.frontend.name
}

output "alb_arn" {
  description = "ALB ARN"
  value       = var.enable_alb ? aws_lb.this[0].arn : null
}

output "alb_dns_name" {
  description = "ALB DNS name"
  value       = var.enable_alb ? aws_lb.this[0].dns_name : null
}

output "alb_zone_id" {
  description = "ALB Route53 zone ID"
  value       = var.enable_alb ? aws_lb.this[0].zone_id : null
}

output "alb_listener_http_arn" {
  description = "HTTP listener ARN"
  value       = var.enable_alb ? aws_lb_listener.http[0].arn : null
}

output "alb_listener_https_arn" {
  description = "HTTPS listener ARN"
  value       = var.enable_alb && var.create_https_listener ? aws_lb_listener.https[0].arn : null
}

# ── CodeDeploy outputs ──

output "codedeploy_app_name" {
  description = "CodeDeploy application name"
  value       = var.enable_codedeploy ? aws_codedeploy_app.this[0].name : null
}

output "codedeploy_deployment_group_name" {
  description = "CodeDeploy deployment group name"
  value       = var.enable_codedeploy ? aws_codedeploy_deployment_group.this[0].deployment_group_name : null
}

output "green_target_group_arn" {
  description = "Green target group ARN (CodeDeploy)"
  value       = var.enable_alb && var.enable_codedeploy ? aws_lb_target_group.green[0].arn : null
}
