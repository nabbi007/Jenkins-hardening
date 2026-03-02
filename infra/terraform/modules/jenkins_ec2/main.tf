data "aws_ssm_parameter" "al2023_ami" {
  name = "/aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64"
}

data "aws_iam_policy_document" "assume_ec2" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "jenkins" {
  name               = "${var.project_name}-jenkins-role"
  assume_role_policy = data.aws_iam_policy_document.assume_ec2.json

  tags = {
    Project = var.project_name
  }
}

resource "aws_iam_role_policy_attachment" "ssm_core" {
  role       = aws_iam_role.jenkins.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
}

data "aws_iam_policy_document" "jenkins_pipeline" {
  statement {
    sid    = "AllowSts"
    effect = "Allow"
    actions = [
      "sts:GetCallerIdentity"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "SecretsManagerRead"
    effect = "Allow"
    actions = [
      "secretsmanager:GetSecretValue",
      "secretsmanager:DescribeSecret",
      "secretsmanager:ListSecrets"
    ]
    resources = ["arn:aws:secretsmanager:${var.aws_region}:*:secret:jenkins/*"]
  }

  statement {
    sid    = "AllowEcrAuth"
    effect = "Allow"
    actions = [
      "ecr:GetAuthorizationToken"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowEcrPushPullAndLifecycle"
    effect = "Allow"
    actions = [
      "ecr:BatchCheckLayerAvailability",
      "ecr:BatchGetImage",
      "ecr:CompleteLayerUpload",
      "ecr:DescribeImages",
      "ecr:DescribeRepositories",
      "ecr:GetDownloadUrlForLayer",
      "ecr:InitiateLayerUpload",
      "ecr:ListImages",
      "ecr:PutImage",
      "ecr:PutLifecyclePolicy",
      "ecr:UploadLayerPart"
    ]
    resources = var.ecr_repository_arns
  }

  statement {
    sid    = "AllowEcsDeployOperations"
    effect = "Allow"
    actions = [
      "ecs:DescribeServices",
      "ecs:DescribeTaskDefinition",
      "ecs:DeregisterTaskDefinition",
      "ecs:ListTaskDefinitions",
      "ecs:RegisterTaskDefinition",
      "ecs:UpdateService",
      "ecs:ListServices",
      "ecs:ListClusters",
      "ecs:ListTasks",
      "ecs:DescribeTasks"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowCodeDeployOperations"
    effect = "Allow"
    actions = [
      "codedeploy:CreateDeployment",
      "codedeploy:GetDeployment",
      "codedeploy:GetDeploymentConfig",
      "codedeploy:GetApplicationRevision",
      "codedeploy:RegisterApplicationRevision",
      "codedeploy:GetDeploymentGroup",
      "codedeploy:BatchGetDeployments"
    ]
    resources = ["*"]
  }

  statement {
    sid    = "AllowPassEcsRoles"
    effect = "Allow"
    actions = [
      "iam:PassRole"
    ]
    resources = var.ecs_task_role_arns

    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["ecs-tasks.amazonaws.com"]
    }
  }

  statement {
    sid    = "CloudWatchLogs"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup",
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogGroups"
    ]
    resources = ["arn:aws:logs:${var.aws_region}:*:log-group:/ecs/${var.project_name}/*"]
  }
}

resource "aws_iam_policy" "jenkins_pipeline" {
  name        = "${var.project_name}-jenkins-pipeline-policy"
  description = "Policy used by Jenkins to build, push, and deploy ECS workloads"
  policy      = data.aws_iam_policy_document.jenkins_pipeline.json
}

resource "aws_iam_role_policy_attachment" "jenkins_pipeline" {
  role       = aws_iam_role.jenkins.name
  policy_arn = aws_iam_policy.jenkins_pipeline.arn
}

resource "aws_iam_instance_profile" "jenkins" {
  name = "${var.project_name}-jenkins-instance-profile"
  role = aws_iam_role.jenkins.name
}

resource "aws_security_group" "jenkins" {
  name        = "${var.project_name}-jenkins-sg"
  description = "Security group for Jenkins host"
  vpc_id      = var.vpc_id

  tags = {
    Name    = "${var.project_name}-jenkins-sg"
    Project = var.project_name
  }
}

locals {
  ingress_rules = {
    for pair in setproduct(toset(var.allowed_cidrs), toset(var.ingress_ports)) :
    "${pair[0]}:${pair[1]}" => {
      cidr = pair[0]
      port = pair[1]
    }
  }
}

resource "aws_vpc_security_group_ingress_rule" "jenkins_ingress" {
  for_each = local.ingress_rules

  security_group_id = aws_security_group.jenkins.id
  cidr_ipv4         = each.value.cidr
  from_port         = each.value.port
  to_port           = each.value.port
  ip_protocol       = "tcp"
}

resource "aws_vpc_security_group_egress_rule" "all_out" {
  security_group_id = aws_security_group.jenkins.id
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
}

resource "aws_instance" "jenkins" {
  ami                         = data.aws_ssm_parameter.al2023_ami.value
  instance_type               = var.instance_type
  subnet_id                   = var.subnet_id
  associate_public_ip_address = var.associate_public_ip_address
  key_name                    = var.key_name
  iam_instance_profile        = aws_iam_instance_profile.jenkins.name
  vpc_security_group_ids      = [aws_security_group.jenkins.id]

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_size           = var.root_volume_size
    volume_type           = "gp3"
    encrypted             = true
    delete_on_termination = true
  }

  user_data = templatefile("${path.module}/user_data.sh.tftpl", {
    aws_region = var.aws_region
  })

  tags = {
    Name    = "${var.project_name}-jenkins"
    Project = var.project_name
    Role    = "jenkins"
  }

  depends_on = [
    aws_iam_role_policy_attachment.ssm_core,
    aws_iam_role_policy_attachment.jenkins_pipeline
  ]
}

resource "aws_secretsmanager_secret" "jenkins_ecs_roles" {
  name        = "jenkins/${var.project_name}"
  description = "Jenkins ECS deployment credentials for ${var.project_name}"

  tags = {
    Project                      = var.project_name
    "jenkins:credentials:type"   = "string"
  }
}

resource "aws_secretsmanager_secret_version" "jenkins_ecs_roles" {
  secret_id = aws_secretsmanager_secret.jenkins_ecs_roles.id
  secret_string = jsonencode({
    "ecs-execution-role-arn" = var.ecs_task_role_arns[0]
    "ecs-task-role-arn"      = var.ecs_task_role_arns[1]
  })
}
