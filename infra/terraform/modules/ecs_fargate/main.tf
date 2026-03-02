data "aws_iam_policy_document" "ecs_task_assume_role" {
  statement {
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "execution" {
  count = var.execution_role_arn == null ? 1 : 0

  name               = "${var.project_name}-ecs-execution-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "execution" {
  count = var.execution_role_arn == null ? 1 : 0

  role       = aws_iam_role.execution[0].name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy"
}

resource "aws_iam_role" "task" {
  count = var.task_role_arn == null ? 1 : 0

  name               = "${var.project_name}-ecs-task-role"
  assume_role_policy = data.aws_iam_policy_document.ecs_task_assume_role.json

  tags = {
    Project = var.project_name
  }
}

resource "aws_cloudwatch_log_group" "backend" {
  name              = var.backend_log_group_name
  retention_in_days = 30

  tags = {
    Project = var.project_name
  }
}

resource "aws_cloudwatch_log_group" "frontend" {
  name              = var.frontend_log_group_name
  retention_in_days = 30

  tags = {
    Project = var.project_name
  }
}

resource "aws_ecs_cluster" "this" {
  name = var.cluster_name

  tags = {
    Project = var.project_name
  }
}

resource "aws_security_group" "ecs_service" {
  name        = "${var.project_name}-ecs-service-sg"
  description = "Security group for ECS service"
  vpc_id      = var.vpc_id

  tags = {
    Name    = "${var.project_name}-ecs-service-sg"
    Project = var.project_name
  }
}

resource "aws_security_group" "alb" {
  count = var.enable_alb ? 1 : 0

  name        = "${var.project_name}-alb-sg"
  description = "Security group for Application Load Balancer"
  vpc_id      = var.vpc_id

  tags = {
    Name    = "${var.project_name}-alb-sg"
    Project = var.project_name
  }
}

resource "aws_vpc_security_group_ingress_rule" "alb_http_ingress" {
  for_each = var.enable_alb ? toset(var.alb_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.alb[0].id
  cidr_ipv4         = each.value
  from_port         = var.alb_listener_port
  to_port           = var.alb_listener_port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_ingress_rule" "alb_https_ingress" {
  for_each = var.enable_alb && var.create_https_listener ? toset(var.alb_allowed_cidrs) : toset([])

  security_group_id = aws_security_group.alb[0].id
  cidr_ipv4         = each.value
  from_port         = 443
  to_port           = 443
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "alb_all_egress" {
  count = var.enable_alb ? 1 : 0

  security_group_id = aws_security_group.alb[0].id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "all_egress" {
  security_group_id = aws_security_group.ecs_service.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

locals {
  execution_role_arn       = var.execution_role_arn != null ? var.execution_role_arn : aws_iam_role.execution[0].arn
  task_role_arn            = var.task_role_arn != null ? var.task_role_arn : aws_iam_role.task[0].arn
  effective_alb_subnet_ids = length(var.alb_subnet_ids) > 0 ? var.alb_subnet_ids : var.subnet_ids
  direct_ingress_rules = {
    for pair in setproduct(toset(var.allowed_ingress_cidrs), toset(var.public_ingress_ports)) :
    "${pair[0]}:${pair[1]}" => {
      cidr = pair[0]
      port = pair[1]
    }
  }

  container_definitions = [
    {
      name      = var.backend_container_name
      image     = var.backend_image_uri
      essential = true
      cpu       = var.backend_container_cpu
      memory    = var.backend_container_memory
      portMappings = [
        {
          containerPort = var.backend_container_port
          hostPort      = var.backend_container_port
          protocol      = "tcp"
        }
      ]
      environment = [
        {
          name  = "NODE_ENV"
          value = "production"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = var.backend_log_group_name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
      healthCheck = {
        command = ["NONE"]
      }
    },
    {
      name      = var.frontend_container_name
      image     = var.frontend_image_uri
      essential = true
      cpu       = var.frontend_container_cpu
      memory    = var.frontend_container_memory
      portMappings = [
        {
          containerPort = var.frontend_container_port
          hostPort      = var.frontend_container_port
          protocol      = "tcp"
        }
      ]
      logConfiguration = {
        logDriver = "awslogs"
        options = {
          awslogs-group         = var.frontend_log_group_name
          awslogs-region        = var.aws_region
          awslogs-stream-prefix = "ecs"
        }
      }
      healthCheck = {
        command = ["NONE"]
      }
    }
  ]
}

resource "aws_lb" "this" {
  count = var.enable_alb ? 1 : 0

  name               = substr("${var.project_name}-${var.service_name}-alb", 0, 32)
  internal           = var.alb_internal
  load_balancer_type = "application"
  security_groups    = [aws_security_group.alb[0].id]
  subnets            = local.effective_alb_subnet_ids

  tags = {
    Project = var.project_name
  }
}

resource "aws_lb_target_group" "frontend" {
  count = var.enable_alb ? 1 : 0

  name        = substr("${var.project_name}-${var.service_name}-tg", 0, 32)
  port        = var.frontend_container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200-399"
    path                = var.alb_health_check_path
  }

  tags = {
    Project = var.project_name
    Role    = "blue"
  }
}

# Second (green) target group required by CodeDeploy blue/green deployments
resource "aws_lb_target_group" "green" {
  count = var.enable_alb && var.enable_codedeploy ? 1 : 0

  name        = substr("${var.project_name}-${var.service_name}-tg2", 0, 32)
  port        = var.frontend_container_port
  protocol    = "HTTP"
  vpc_id      = var.vpc_id
  target_type = "ip"

  health_check {
    enabled             = true
    interval            = 30
    timeout             = 5
    healthy_threshold   = 2
    unhealthy_threshold = 3
    matcher             = "200-399"
    path                = var.alb_health_check_path
  }

  tags = {
    Project = var.project_name
    Role    = "green"
  }
}

resource "aws_lb_listener" "http" {
  count = var.enable_alb ? 1 : 0

  load_balancer_arn = aws_lb.this[0].arn
  port              = var.alb_listener_port
  protocol          = "HTTP"

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend[0].arn
  }
}

resource "aws_lb_listener" "https" {
  count = var.enable_alb && var.create_https_listener ? 1 : 0

  load_balancer_arn = aws_lb.this[0].arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = var.alb_ssl_policy
  certificate_arn   = var.alb_certificate_arn

  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.frontend[0].arn
  }

  lifecycle {
    precondition {
      condition     = var.alb_certificate_arn != null && trimspace(var.alb_certificate_arn) != ""
      error_message = "alb_certificate_arn must be provided when create_https_listener is true."
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "public_ingress" {
  for_each = var.enable_alb ? {} : local.direct_ingress_rules

  security_group_id = aws_security_group.ecs_service.id
  cidr_ipv4         = each.value.cidr
  from_port         = each.value.port
  ip_protocol       = "tcp"
  to_port           = each.value.port
}

resource "aws_vpc_security_group_ingress_rule" "frontend_from_alb" {
  count = var.enable_alb ? 1 : 0

  security_group_id            = aws_security_group.ecs_service.id
  referenced_security_group_id = aws_security_group.alb[0].id
  from_port                    = var.frontend_container_port
  to_port                      = var.frontend_container_port
  ip_protocol                  = "tcp"
}

resource "aws_ecs_task_definition" "this" {
  family                   = var.task_family
  network_mode             = "awsvpc"
  requires_compatibilities = ["FARGATE"]
  cpu                      = tostring(var.task_cpu)
  memory                   = tostring(var.task_memory)
  execution_role_arn       = local.execution_role_arn
  task_role_arn            = local.task_role_arn
  container_definitions    = jsonencode(local.container_definitions)
}

resource "aws_ecs_service" "this" {
  name                   = var.service_name
  cluster                = aws_ecs_cluster.this.id
  task_definition        = aws_ecs_task_definition.this.arn
  desired_count          = var.desired_count
  launch_type            = "FARGATE"
  platform_version       = "LATEST"
  enable_execute_command = true

  deployment_controller {
    type = var.enable_codedeploy ? "CODE_DEPLOY" : "ECS"
  }

  # Circuit breaker is only valid with the ECS deployment controller
  dynamic "deployment_circuit_breaker" {
    for_each = var.enable_codedeploy ? [] : [1]
    content {
      enable   = true
      rollback = true
    }
  }

  deployment_minimum_healthy_percent = var.enable_codedeploy ? 100 : 50
  deployment_maximum_percent         = 200

  dynamic "load_balancer" {
    for_each = var.enable_alb ? [1] : []
    content {
      target_group_arn = aws_lb_target_group.frontend[0].arn
      container_name   = var.frontend_container_name
      container_port   = var.frontend_container_port
    }
  }

  network_configuration {
    subnets          = var.subnet_ids
    security_groups  = [aws_security_group.ecs_service.id]
    assign_public_ip = var.assign_public_ip
  }

  lifecycle {
    ignore_changes = [task_definition, load_balancer]
  }

  depends_on = [
    aws_cloudwatch_log_group.backend,
    aws_cloudwatch_log_group.frontend,
    aws_lb_listener.http,
    aws_lb_listener.https
  ]
}

# ──────────────────────────────────────────────────
# CodeDeploy — blue/green deployment resources
# ──────────────────────────────────────────────────

data "aws_iam_policy_document" "codedeploy_assume_role" {
  count = var.enable_codedeploy ? 1 : 0

  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["codedeploy.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "codedeploy" {
  count = var.enable_codedeploy ? 1 : 0

  name               = "${var.project_name}-codedeploy-role"
  assume_role_policy = data.aws_iam_policy_document.codedeploy_assume_role[0].json

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "codedeploy_ecs" {
  count = var.enable_codedeploy ? 1 : 0

  role       = aws_iam_role.codedeploy[0].name
  policy_arn = "arn:aws:iam::aws:policy/AWSCodeDeployRoleForECS"
}

resource "aws_codedeploy_app" "this" {
  count = var.enable_codedeploy ? 1 : 0

  compute_platform = "ECS"
  name             = "${var.project_name}-deploy"

  tags = {
    Project = var.project_name
  }
}

resource "aws_codedeploy_deployment_group" "this" {
  count = var.enable_codedeploy ? 1 : 0

  app_name               = aws_codedeploy_app.this[0].name
  deployment_group_name  = "${var.project_name}-dg"
  deployment_config_name = "CodeDeployDefault.ECSAllAtOnce"
  service_role_arn       = aws_iam_role.codedeploy[0].arn

  auto_rollback_configuration {
    enabled = true
    events  = ["DEPLOYMENT_FAILURE"]
  }

  blue_green_deployment_config {
    deployment_ready_option {
      action_on_timeout = "CONTINUE_DEPLOYMENT"
    }
    terminate_blue_instances_on_deployment_success {
      action                           = "TERMINATE"
      termination_wait_time_in_minutes = var.codedeploy_termination_wait
    }
  }

  deployment_style {
    deployment_option = "WITH_TRAFFIC_CONTROL"
    deployment_type   = "BLUE_GREEN"
  }

  ecs_service {
    cluster_name = aws_ecs_cluster.this.name
    service_name = aws_ecs_service.this.name
  }

  load_balancer_info {
    target_group_pair_info {
      prod_traffic_route {
        listener_arns = [aws_lb_listener.http[0].arn]
      }
      target_group {
        name = aws_lb_target_group.frontend[0].name
      }
      target_group {
        name = aws_lb_target_group.green[0].name
      }
    }
  }

  depends_on = [aws_ecs_service.this]
}
