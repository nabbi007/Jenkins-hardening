data "aws_vpc" "default" {
  count   = var.vpc_id == null ? 1 : 0
  default = true
}

data "aws_subnets" "selected" {
  count = length(var.subnet_ids) == 0 ? 1 : 0

  filter {
    name   = "vpc-id"
    values = [var.vpc_id != null ? var.vpc_id : data.aws_vpc.default[0].id]
  }
}

locals {
  effective_vpc_id                  = var.vpc_id != null ? var.vpc_id : data.aws_vpc.default[0].id
  effective_subnet_ids              = length(var.subnet_ids) > 0 ? var.subnet_ids : data.aws_subnets.selected[0].ids
  effective_jenkins_subnet_id       = var.jenkins_subnet_id != null ? var.jenkins_subnet_id : local.effective_subnet_ids[0]
  effective_jenkins_allowed_cidrs   = length(var.jenkins_allowed_cidrs) > 0 ? var.jenkins_allowed_cidrs : var.allowed_ingress_cidrs
  effective_alb_certificate_arn     = trimspace(var.alb_certificate_arn != null ? var.alb_certificate_arn : "")
  enable_alb_https                  = local.effective_alb_certificate_arn != ""
  effective_jenkins_key_name        = var.jenkins_key_name != null && trimspace(var.jenkins_key_name) != "" ? trimspace(var.jenkins_key_name) : null
  effective_jenkins_public_key_path = var.jenkins_public_key_path != null ? trimspace(var.jenkins_public_key_path) : ""
  effective_jenkins_key_pair_name   = var.jenkins_key_pair_name != null && trimspace(var.jenkins_key_pair_name) != "" ? trimspace(var.jenkins_key_pair_name) : "${var.project_name}-jenkins-key"
  create_jenkins_key_pair           = var.create_jenkins_instance && local.effective_jenkins_key_name == null && local.effective_jenkins_public_key_path != ""

  repositories = [
    var.backend_ecr_repo_name,
    var.frontend_ecr_repo_name
  ]
}

resource "aws_key_pair" "jenkins" {
  count = local.create_jenkins_key_pair ? 1 : 0

  key_name   = local.effective_jenkins_key_pair_name
  public_key = file(local.effective_jenkins_public_key_path)

  tags = {
    Project = var.project_name
    Role    = "jenkins"
  }
}

module "ecr" {
  source = "./modules/ecr"

  project_name          = var.project_name
  repositories          = local.repositories
  create_repositories   = var.ecr_create_repositories
  lifecycle_keep_images = var.ecr_lifecycle_keep_images
}

module "ecs_fargate" {
  source = "./modules/ecs_fargate"

  project_name          = var.project_name
  aws_region            = var.aws_region
  cluster_name          = var.ecs_cluster_name
  service_name          = var.ecs_service_name
  task_family           = var.ecs_task_family
  desired_count         = var.desired_count
  assign_public_ip      = var.assign_public_ip
  vpc_id                = local.effective_vpc_id
  subnet_ids            = local.effective_subnet_ids
  allowed_ingress_cidrs = var.allowed_ingress_cidrs
  public_ingress_ports  = var.ecs_public_ingress_ports
  enable_alb            = var.enable_ecs_alb
  alb_subnet_ids        = var.alb_subnet_ids
  alb_allowed_cidrs     = var.alb_allowed_cidrs
  alb_internal          = var.alb_internal
  alb_listener_port     = var.alb_listener_port
  alb_health_check_path = var.alb_health_check_path
  create_https_listener = local.enable_alb_https
  alb_certificate_arn   = local.enable_alb_https ? local.effective_alb_certificate_arn : null
  alb_ssl_policy        = var.alb_ssl_policy

  task_cpu                  = var.task_cpu
  task_memory               = var.task_memory
  backend_container_cpu     = var.backend_container_cpu
  backend_container_memory  = var.backend_container_memory
  frontend_container_cpu    = var.frontend_container_cpu
  frontend_container_memory = var.frontend_container_memory
  backend_container_port    = var.backend_container_port
  frontend_container_port   = var.frontend_container_port

  backend_container_name  = "backend"
  frontend_container_name = "frontend"
  backend_image_uri       = "${module.ecr.repository_urls[var.backend_ecr_repo_name]}:${var.backend_image_tag}"
  frontend_image_uri      = "${module.ecr.repository_urls[var.frontend_ecr_repo_name]}:${var.frontend_image_tag}"

  backend_log_group_name  = var.backend_log_group_name
  frontend_log_group_name = var.frontend_log_group_name

  execution_role_arn = var.execution_role_arn
  task_role_arn      = var.task_role_arn

  enable_codedeploy          = var.enable_codedeploy
  codedeploy_termination_wait = var.codedeploy_termination_wait
}

module "cloudwatch_alarms" {
  source = "./modules/cloudwatch_alarms"

  project_name           = var.project_name
  ecs_cluster_name       = module.ecs_fargate.cluster_name
  ecs_service_name       = module.ecs_fargate.service_name
  alarm_sns_topic_arn    = var.alarm_sns_topic_arn
  cpu_alarm_threshold    = var.cpu_alarm_threshold
  memory_alarm_threshold = var.memory_alarm_threshold
}

module "jenkins_ec2" {
  count  = var.create_jenkins_instance ? 1 : 0
  source = "./modules/jenkins_ec2"

  project_name                = var.project_name
  aws_region                  = var.aws_region
  vpc_id                      = local.effective_vpc_id
  subnet_id                   = local.effective_jenkins_subnet_id
  instance_type               = var.jenkins_instance_type
  root_volume_size            = var.jenkins_root_volume_size
  key_name                    = local.effective_jenkins_key_name != null ? local.effective_jenkins_key_name : (local.create_jenkins_key_pair ? aws_key_pair.jenkins[0].key_name : null)
  allowed_cidrs               = local.effective_jenkins_allowed_cidrs
  ingress_ports               = var.jenkins_ingress_ports
  associate_public_ip_address = var.jenkins_associate_public_ip
  ecr_repository_arns         = values(module.ecr.repository_arns)
  ecs_task_role_arns = [
    module.ecs_fargate.execution_role_arn,
    module.ecs_fargate.task_role_arn
  ]
}
