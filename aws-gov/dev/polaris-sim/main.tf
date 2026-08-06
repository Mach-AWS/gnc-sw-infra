# ==========================================================
# MACH Industries — Unreal render infrastructure (GovCloud)
# ==========================================================
# Everything except IAM. The three IAM roles live in iam.tf because the access
# request (aws-govcloud-permissions-request-new.md, Part A) frames them as IT's
# one-time create — keeping them separate lets IT apply that file alone, or lets
# us reference roles IT already made.
#
# Compute is ECS on EC2, not Fargate: Fargate cannot attach a GPU.
# Topology follows three-stack-cloud-architecture.md — node 0 (Unreal + PX4
# SITL) on a g4dn.2xlarge pinned to a single AZ.
# ==========================================================


# ----------------------------------------------------------
# Providers
# ----------------------------------------------------------
terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }

    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4"
    }
  }

  required_version = ">= 1.3"
}

provider "aws" {
  region = var.region
}


# ----------------------------------------------------------
# Variables
# ----------------------------------------------------------
variable "region" {
  description = "AWS GovCloud region"
  type        = string
  default     = "us-gov-west-1"
}

variable "region_name" {
  description = "Short region token used in resource names (matches the VPC repo convention)"
  type        = string
  default     = "ore"
}

variable "env" {
  type    = string
  default = "dev"
}

variable "purpose" {
  description = "Name segment; keeps resources grouped with the TestDev VPC naming scheme"
  type        = string
  default     = "polaris-sim"
}

variable "project" {
  type    = string
  default = "GC-Unreal-Render-Infrastructure"
}

# ----------------------------------------------------------
# Network — consumes the VPC built by mach-gc-TestDev-infra.
# Looked up by tag so this config does not need that state.
# ----------------------------------------------------------

variable "vpc_name" {
  default     = "mi-testdev-dev-ore-vpc"
  description = "Name tag of the existing VPC to deploy into"
  type        = string
}

variable "private_subnet_names" {
  description = "Name tags of the private subnets to run tasks in"
  type        = list(string)
  default = [
    "mi-testdev-dev-ore-us-gov-west-1a-private",
    "mi-testdev-dev-ore-us-gov-west-1b-private",
  ]
}

# ----------------------------------------------------------
# Compute
# ----------------------------------------------------------

variable "instance_type_unreal" {
  description = "Node 0: Unreal + PX4 SITL + JSBSim on one T4 (8 vCPU)"
  type        = string
  default     = "g4dn.2xlarge"
}

variable "instance_type_polaris" {
  description = "Node 1: polaris-strike + sim-image-receiver + uxrce-agent on one T4 (4 vCPU)"
  type        = string
  default     = "g4dn.xlarge"
}

variable "az" {
  description = "Single AZ - the architecture doc pins the rig to us-gov-west-1a"
  type        = string
  default     = "us-gov-west-1a"
}

variable "min_instances" {
  description = "0 lets the cluster scale to zero when no render tasks are queued"
  type        = number
  default     = 0
}

variable "max_instances" {
  type    = number
  default = 2
}

variable "root_volume_gb" {
  description = "Unreal images plus Content are large; 116 GB was the working figure on the T4 box"
  type        = number
  default     = 200
}

variable "task_gpu_count" {
  type    = number
  default = 1
}

variable "unreal_task_cpu" {
  description = "vCPU units for node 0 (g4dn.2xlarge = 8 vCPU = 8192)"
  type        = number
  default     = 7680
}

variable "unreal_task_memory" {
  description = "MiB for node 0 (g4dn.2xlarge = 32 GiB)"
  type        = number
  default     = 30720
}

variable "polaris_task_cpu" {
  description = "vCPU units for node 1 (g4dn.xlarge = 4 vCPU = 4096)"
  type        = number
  default     = 3584
}

variable "polaris_task_memory" {
  description = "MiB for node 1 (g4dn.xlarge = 16 GiB)"
  type        = number
  default     = 14336
}

# ----------------------------------------------------------
# Storage
# ----------------------------------------------------------

variable "ecr_repo_name" {
  type    = string
  default = "mach-industries/mach-unreal"
}

variable "polaris_ecr_repo_name" {
  description = "Polaris cloud image — runs polaris-strike and uxrce-agent"
  type        = string
  default     = "mach-industries/polaris-cloud"
}

variable "receiver_ecr_repo_name" {
  description = "sim-image-receiver — takes Unreal's frames into the Polaris pipeline"
  type        = string
  default     = "mach-industries/polaris-unreal-receiver"
}

variable "ecr_keep_images" {
  description = "Untagged images beyond this count are expired; Unreal layers are big"
  type        = number
  default     = 10
}

variable "artifacts_bucket" {
  default     = "mach-polaris-sim-artifacts"
  description = "Run artifacts bucket (access request: mach-polaris-sim-artifacts)"
  type        = string
}

variable "gis_bucket" {
  default     = "mach-polaris-gis"
  description = "GIS tile bucket, read-only for tasks (access request: mach-polaris-gis)"
  type        = string
}

variable "create_buckets" {
  description = "Create the artifacts bucket. false = IT owns it."
  type        = bool
  default     = false
}

variable "tile_service_cidr" {
  description = "Host serving Google 3D tiles inside the VPC. Tasks reach imagery here, not the internet."
  type        = string
  default     = "172.23.5.51/32"
}

variable "tile_service_port" {
  type    = number
  default = 443
}

variable "jetson_cidr" {
  description = "HQ Jetson hardware network. Real devices talk to the rig over the TGW path; scope-tighten to explicit ports once the SW team pins the protocol set."
  type        = string
  default     = "10.73.106.0/24"
}

variable "enable_ssm_endpoints" {
  description = "Adds the three SSM endpoints so Session Manager works without egress. ~3x endpoint cost."
  type        = bool
  default     = false
}

variable "create_vpc_endpoints" {
  description = "Create S3 gateway + ECR/logs interface endpoints. false = reuse the ones already in the VPC (sagemaker-studio root owns ecr.api/ecr.dkr/logs + an S3 gateway on both private route tables; its endpoint SG admits 443 from the private-subnet CIDRs)."
  type        = bool
  default     = false
}

variable "tags" {
  type    = map(string)
  default = {}
}


# ----------------------------------------------------------
# Network — existing VPC lookup + S3 gateway endpoint
# ----------------------------------------------------------
data "aws_vpc" "this" {
  filter {
    name   = "tag:Name"
    values = [var.vpc_name]
  }
}

data "aws_subnet" "private" {
  for_each = toset(var.private_subnet_names)

  filter {
    name   = "tag:Name"
    values = [each.value]
  }
}

locals {
  name       = "mi-${var.purpose}-${var.env}-${var.region_name}"
  subnet_ids = [for s in data.aws_subnet.private : s.id]
  # The rig is pinned to one AZ so both nodes land together (architecture doc SS4).
  az_subnet_ids  = [for s in data.aws_subnet.private : s.id if s.availability_zone == var.az]
  route_table_id = data.aws_vpc.this.main_route_table_id

  tags = merge({
    Environment = var.env
    Project     = var.project
    Purpose     = var.purpose
    Owner       = "IT@machindustries.com"
  }, var.tags)
}

data "aws_route_tables" "private" {
  vpc_id = data.aws_vpc.this.id

  filter {
    name   = "tag:Name"
    values = ["*private*"]
  }
}

# S3 gateway endpoint: render output and Content pulls stay inside the VPC.
# Gated: the sagemaker-studio root already put an S3 gateway on both private
# route tables (vpce-0a013e8a25a12709c); a VPC allows only one per route table.
resource "aws_vpc_endpoint" "s3" {
  count             = var.create_vpc_endpoints ? 1 : 0
  vpc_id            = data.aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = data.aws_route_tables.private.ids

  tags = merge(local.tags, { Name = "${local.name}-s3-endpoint" })
}


# ----------------------------------------------------------
# ECR — renderer image registry
# ----------------------------------------------------------
locals {
  # One repo per image. polaris-cloud runs BOTH polaris-strike and uxrce-agent — same
  # image, different command — so it is one repo serving two containers.
  ecr_repos = toset([
    var.ecr_repo_name,          # mach-industries/mach-unreal            : renderer + PX4 SITL runtime
    var.polaris_ecr_repo_name,  # mach-industries/polaris-cloud          : polaris-strike AND uxrce-agent
    var.receiver_ecr_repo_name, # mach-industries/polaris-unreal-receiver : sim-image-receiver
  ])
}

resource "aws_ecr_repository" "rig" {
  for_each = local.ecr_repos

  name                 = each.value
  image_tag_mutability = "MUTABLE"

  image_scanning_configuration {
    scan_on_push = true
  }

  encryption_configuration {
    encryption_type = "AES256"
  }

  tags = merge(local.tags, { Name = each.value })
}

resource "aws_ecr_lifecycle_policy" "rig" {
  for_each   = local.ecr_repos
  repository = aws_ecr_repository.rig[each.value].name

  policy = jsonencode({
    rules = [
      {
        rulePriority = 1
        description  = "Expire untagged images beyond the newest ${var.ecr_keep_images}"
        selection = {
          tagStatus   = "untagged"
          countType   = "imageCountMoreThan"
          countNumber = var.ecr_keep_images
        }
        action = { type = "expire" }
      }
    ]
  })
}


# ----------------------------------------------------------
# S3 — run artifacts + GIS tiles
# ----------------------------------------------------------
data "aws_s3_bucket" "artifacts" {
  count  = var.create_buckets ? 0 : 1
  bucket = var.artifacts_bucket
}

resource "aws_s3_bucket" "artifacts" {
  count  = var.create_buckets ? 1 : 0
  bucket = var.artifacts_bucket
  tags   = merge(local.tags, { Name = var.artifacts_bucket })
}

resource "aws_s3_bucket_public_access_block" "artifacts" {
  count                   = var.create_buckets ? 1 : 0
  bucket                  = aws_s3_bucket.artifacts[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "artifacts" {
  count  = var.create_buckets ? 1 : 0
  bucket = aws_s3_bucket.artifacts[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# GIS tile bucket. Ted's pack referenced it by name only (assumed pre-existing);
# neither bucket existed in the account, so the platform root owns both.
resource "aws_s3_bucket" "gis" {
  count  = var.create_buckets ? 1 : 0
  bucket = var.gis_bucket
  tags   = merge(local.tags, { Name = var.gis_bucket })
}

resource "aws_s3_bucket_public_access_block" "gis" {
  count                   = var.create_buckets ? 1 : 0
  bucket                  = aws_s3_bucket.gis[0].id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_server_side_encryption_configuration" "gis" {
  count  = var.create_buckets ? 1 : 0
  bucket = aws_s3_bucket.gis[0].id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}


# ----------------------------------------------------------
# ECS — GPU cluster, capacity provider, task definition
# ----------------------------------------------------------
data "aws_ssm_parameter" "ecs_gpu_ami" {
  name = "/aws/service/ecs/optimized-ami/amazon-linux-2/gpu/recommended/image_id"
}

resource "aws_ecs_cluster" "unreal" {
  name = "${local.name}-cluster"

  setting {
    name  = "containerInsights"
    value = "enabled"
  }

  tags = local.tags
}

# Default-deny egress. The task needs exactly three destinations: the in-VPC tile
# service, S3 (via the gateway endpoint's prefix list), and the interface endpoints
# for ECR/logs. Anything else - including the public internet - is refused here
# rather than left to the Transit Gateway's policy.
data "aws_prefix_list" "s3" {
  name = "com.amazonaws.${var.region}.s3"
}

resource "aws_security_group" "instances" {
  name        = "${local.name}-sg"
  description = "Unreal render instances"
  vpc_id      = data.aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.name}-sg" })
}

resource "aws_vpc_security_group_egress_rule" "tiles" {
  security_group_id = aws_security_group.instances.id
  description       = "Google 3D tiles served in-VPC"
  cidr_ipv4         = var.tile_service_cidr
  ip_protocol       = "tcp"
  from_port         = var.tile_service_port
  to_port           = var.tile_service_port
}

resource "aws_vpc_security_group_egress_rule" "s3" {
  security_group_id = aws_security_group.instances.id
  description       = "S3 via gateway endpoint (image layers, artifacts, staged tiles)"
  prefix_list_id    = data.aws_prefix_list.s3.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
}

# HQ Jetson hardware <-> rig, over the TGW path. All protocols within the pinned
# CIDR for now (uORB/DDS + camera streams span many ports); tighten to an explicit
# port set once the SW team pins the protocol matrix. The TGW/HQ-firewall leg is a
# separate network-team gate — these rules are necessary, not sufficient.
resource "aws_vpc_security_group_ingress_rule" "jetson" {
  security_group_id = aws_security_group.instances.id
  description       = "HQ Jetson devices to rig nodes"
  cidr_ipv4         = var.jetson_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "jetson" {
  security_group_id = aws_security_group.instances.id
  description       = "Rig nodes to HQ Jetson devices"
  cidr_ipv4         = var.jetson_cidr
  ip_protocol       = "-1"
}

resource "aws_vpc_security_group_egress_rule" "endpoints" {
  for_each = toset(local.endpoint_sg_ids)

  security_group_id            = aws_security_group.instances.id
  description                  = "ECR / CloudWatch Logs interface endpoints"
  referenced_security_group_id = each.value
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

# Node 0 <-> node 1. Both task ENIs carry this SG, and every link between them is
# intra-SG: Unreal's frames to sim-image-receiver, PX4 to uxrce-agent, Polaris back to
# PX4. Without this pair the rig places cleanly and then does nothing at all.
resource "aws_vpc_security_group_ingress_rule" "rig_peer" {
  security_group_id            = aws_security_group.instances.id
  description                  = "Rig node to rig node"
  referenced_security_group_id = aws_security_group.instances.id
  ip_protocol                  = "-1"
}

resource "aws_vpc_security_group_egress_rule" "rig_peer" {
  security_group_id            = aws_security_group.instances.id
  description                  = "Rig node to rig node"
  referenced_security_group_id = aws_security_group.instances.id
  ip_protocol                  = "-1"
}

# The tile host initiates back to the renderer.
resource "aws_vpc_security_group_ingress_rule" "tiles" {
  security_group_id = aws_security_group.instances.id
  description       = "Return/initiated traffic from the tile service"
  cidr_ipv4         = var.tile_service_cidr
  ip_protocol       = "tcp"
  from_port         = var.tile_service_port
  to_port           = var.tile_service_port
}

resource "aws_security_group" "endpoints" {
  count       = var.create_vpc_endpoints ? 1 : 0
  name        = "${local.name}-endpoints-sg"
  description = "Interface VPC endpoints for the render cluster"
  vpc_id      = data.aws_vpc.this.id

  tags = merge(local.tags, { Name = "${local.name}-endpoints-sg" })
}

resource "aws_vpc_security_group_ingress_rule" "endpoints" {
  count                        = var.create_vpc_endpoints ? 1 : 0
  security_group_id            = aws_security_group.endpoints[0].id
  referenced_security_group_id = aws_security_group.instances.id
  ip_protocol                  = "tcp"
  from_port                    = 443
  to_port                      = 443
}

# Existing interface endpoints in the VPC (sagemaker-studio root owns them).
# Their SG admits 443 from the private-subnet CIDRs, which covers the rig ENIs.
data "aws_vpc_endpoint" "existing" {
  for_each     = var.create_vpc_endpoints ? toset([]) : toset(["ecr.api", "ecr.dkr", "logs"])
  vpc_id       = data.aws_vpc.this.id
  service_name = "com.amazonaws.${var.region}.${each.value}"
}

locals {
  # SG(s) fronting the interface endpoints the rig talks to, created or reused.
  endpoint_sg_ids = var.create_vpc_endpoints ? [aws_security_group.endpoints[0].id] : distinct(flatten([
    for e in data.aws_vpc_endpoint.existing : e.security_group_ids
  ]))
}

# ECR pulls need both endpoints; layers themselves come from S3 via the gateway.
locals {
  interface_endpoints = var.create_vpc_endpoints ? toset(concat(
    ["ecr.api", "ecr.dkr", "logs"],
    var.enable_ssm_endpoints ? ["ssm", "ssmmessages", "ec2messages"] : [],
  )) : toset([])
}

resource "aws_vpc_endpoint" "interface" {
  for_each = local.interface_endpoints

  vpc_id              = data.aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.value}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.az_subnet_ids
  security_group_ids  = [aws_security_group.endpoints[0].id]
  private_dns_enabled = true

  tags = merge(local.tags, { Name = "${local.name}-${each.value}-endpoint" })
}

# One ASG + capacity provider per node type. A single mixed ASG would let ECS place
# the Polaris task on a 2xlarge (or fail to place Unreal on an xlarge); separating them
# makes placement deterministic and lets each scale to zero independently.
locals {
  nodes = {
    unreal  = { instance_type = var.instance_type_unreal }
    polaris = { instance_type = var.instance_type_polaris }
  }
}

resource "aws_launch_template" "node" {
  for_each = local.nodes

  name_prefix   = "${local.name}-${each.key}-"
  image_id      = data.aws_ssm_parameter.ecs_gpu_ami.value
  instance_type = each.value.instance_type

  iam_instance_profile {
    arn = data.aws_iam_instance_profile.instance.arn
  }

  vpc_security_group_ids = [aws_security_group.instances.id]

  block_device_mappings {
    device_name = "/dev/xvda"

    ebs {
      volume_size           = var.root_volume_gb
      volume_type           = "gp3"
      encrypted             = true
      delete_on_termination = true
    }
  }

  user_data = base64encode(<<-EOT
    #!/bin/bash
    echo ECS_CLUSTER=${aws_ecs_cluster.unreal.name} >> /etc/ecs/ecs.config
    echo ECS_ENABLE_GPU_SUPPORT=true >> /etc/ecs/ecs.config
    echo ECS_INSTANCE_ATTRIBUTES='{"rig.node":"${each.key}"}' >> /etc/ecs/ecs.config
  EOT
  )

  tag_specifications {
    resource_type = "instance"
    tags          = merge(local.tags, { Name = "${local.name}-${each.key}" })
  }

  tags = local.tags
}

resource "aws_autoscaling_group" "node" {
  for_each = local.nodes

  name                = "${local.name}-${each.key}-asg"
  vpc_zone_identifier = local.az_subnet_ids
  min_size            = var.min_instances
  max_size            = var.max_instances
  desired_capacity    = var.min_instances

  launch_template {
    id      = aws_launch_template.node[each.key].id
    version = "$Latest"
  }

  protect_from_scale_in = true

  tag {
    key                 = "AmazonECSManaged"
    value               = ""
    propagate_at_launch = true
  }

  dynamic "tag" {
    for_each = local.tags
    content {
      key                 = tag.key
      value               = tag.value
      propagate_at_launch = true
    }
  }

  lifecycle {
    ignore_changes = [desired_capacity]
  }
}

resource "aws_ecs_capacity_provider" "node" {
  for_each = local.nodes

  name = "${local.name}-${each.key}-cp"

  auto_scaling_group_provider {
    auto_scaling_group_arn         = aws_autoscaling_group.node[each.key].arn
    managed_termination_protection = "ENABLED"

    managed_scaling {
      status                    = "ENABLED"
      target_capacity           = 100
      minimum_scaling_step_size = 1
      maximum_scaling_step_size = 1
    }
  }

  tags = local.tags
}

resource "aws_ecs_cluster_capacity_providers" "unreal" {
  cluster_name       = aws_ecs_cluster.unreal.name
  capacity_providers = [for k in keys(local.nodes) : aws_ecs_capacity_provider.node[k].name]
}

resource "aws_cloudwatch_log_group" "unreal" {
  name              = "/ecs/${local.name}"
  retention_in_days = 30
  tags              = local.tags
}

# Render job definition. Run with `aws ecs run-task`, not a long-lived service —
# these are batch renders that exit.
# Two task definitions, one per node, launched together as a rig. Both are awsvpc and
# both claim a GPU; peer discovery is ecs:ListTasks filtered on startedBy (the run id),
# which avoids Cloud Map and the servicediscovery permissions the dev role does not have.
resource "aws_ecs_task_definition" "unreal" {
  family                   = "${local.name}-unreal"
  network_mode             = "awsvpc"
  execution_role_arn       = data.aws_iam_role.task_execution.arn
  task_role_arn            = data.aws_iam_role.task.arn
  cpu                      = var.unreal_task_cpu
  memory                   = var.unreal_task_memory
  requires_compatibilities = ["EC2"]

  placement_constraints {
    type       = "memberOf"
    expression = "attribute:rig.node == unreal"
  }

  container_definitions = jsonencode([
    {
      name                 = "unreal"
      image                = "${aws_ecr_repository.rig[var.ecr_repo_name].repository_url}:latest"
      essential            = true
      resourceRequirements = [{ type = "GPU", value = tostring(var.task_gpu_count) }]

      environment = [
        { name = "ARTIFACTS_BUCKET", value = var.artifacts_bucket },
        { name = "GIS_BUCKET", value = var.gis_bucket },
        { name = "TILE_SERVICE", value = var.tile_service_cidr },
        { name = "AWS_REGION", value = var.region },
        { name = "RIG_NODE", value = "unreal" },
      ]


      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.unreal.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "unreal"
        }
      }
    },
    {
      # Same image as the renderer: PX4 <-> JSBSim lockstep is hard real time, so it must not
      # cross a network boundary. awsvpc gives these two containers one network namespace.
      name      = "px4-sitl"
      essential = true
      image     = "${aws_ecr_repository.rig[var.ecr_repo_name].repository_url}:latest"

      environment = [
        { name = "ARTIFACTS_BUCKET", value = var.artifacts_bucket },
        { name = "AWS_REGION", value = var.region },
        { name = "RIG_NODE", value = "unreal" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.unreal.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "px4"
        }
      }
    }
  ])

  tags = local.tags
}

resource "aws_ecs_task_definition" "polaris" {
  family                   = "${local.name}-polaris"
  network_mode             = "awsvpc"
  execution_role_arn       = data.aws_iam_role.task_execution.arn
  task_role_arn            = data.aws_iam_role.task.arn
  cpu                      = var.polaris_task_cpu
  memory                   = var.polaris_task_memory
  requires_compatibilities = ["EC2"]

  placement_constraints {
    type       = "memberOf"
    expression = "attribute:rig.node == polaris"
  }

  container_definitions = jsonencode([
    {
      name                 = "polaris-strike"
      image                = "${aws_ecr_repository.rig[var.polaris_ecr_repo_name].repository_url}:latest"
      essential            = true
      resourceRequirements = [{ type = "GPU", value = tostring(var.task_gpu_count) }]

      environment = [
        { name = "ARTIFACTS_BUCKET", value = var.artifacts_bucket },
        { name = "GIS_BUCKET", value = var.gis_bucket },
        { name = "AWS_REGION", value = var.region },
        { name = "RIG_NODE", value = "polaris" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.unreal.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "polaris-strike"
        }
      }
    },
    {
      # Receives Unreal's frames over the network and feeds the Polaris pipeline.
      name      = "sim-image-receiver"
      image     = "${aws_ecr_repository.rig[var.receiver_ecr_repo_name].repository_url}:latest"
      essential = true

      environment = [
        { name = "AWS_REGION", value = var.region },
        { name = "RIG_NODE", value = "polaris" },
      ]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.unreal.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "receiver"
        }
      }
    },
    {
      # Same image as polaris-strike, different command — the uORB/DDS bridge to PX4.
      name      = "uxrce-agent"
      image     = "${aws_ecr_repository.rig[var.polaris_ecr_repo_name].repository_url}:latest"
      essential = true
      command   = ["MicroXRCEAgent", "udp4", "-p", "8888"]

      logConfiguration = {
        logDriver = "awslogs"
        options = {
          "awslogs-group"         = aws_cloudwatch_log_group.unreal.name
          "awslogs-region"        = var.region
          "awslogs-stream-prefix" = "uxrce"
        }
      }
    }
  ])

  tags = local.tags
}

# ----------------------------------------------------------
# Outputs
# ----------------------------------------------------------
output "ecr_repository_urls" {
  description = "Push each rig image to its repo"
  value       = { for k, r in aws_ecr_repository.rig : k => r.repository_url }
}

output "artifacts_bucket" {
  value = var.artifacts_bucket
}

output "rig_api_endpoint" {
  description = "POST /runs here (SigV4). This is the only thing operators need."
  value       = aws_apigatewayv2_stage.rig.invoke_url
}

output "ecs_cluster_name" {
  value = aws_ecs_cluster.unreal.name
}

output "task_definition_unreal" {
  value = aws_ecs_task_definition.unreal.family
}

output "task_definition_polaris" {
  value = aws_ecs_task_definition.polaris.family
}

output "subnet_ids" {
  description = "Pass these to run-task --network-configuration"
  value       = local.az_subnet_ids
}

output "security_group_id" {
  value = aws_security_group.instances.id
}


# ----------------------------------------------------------
# Role lookups — resolve whichever exists, created here or by IT
# ----------------------------------------------------------
# Created by ../polaris-sim-iam. If apply fails here with "no IAM role found", that is the
# whole diagnosis: IT has not applied the IAM config to this account yet.
data "aws_iam_role" "task_execution" {
  name = "mach-gnc-polaris-sim-task-execution"
}

data "aws_iam_role" "task" {
  name = "mach-gnc-polaris-sim-task"
}

data "aws_iam_instance_profile" "instance" {
  name = "mach-gnc-polaris-sim-instance"
}


# ----------------------------------------------------------
# Control plane — API Gateway (SigV4) -> Lambda "rig orchestrator"
# ----------------------------------------------------------
# Same front door as Monte Carlo. This exists so that running a rig does not require
# ECS permissions: the orchestrator holds ecs:RunTask and iam:PassRole, and callers
# hold only execute-api:Invoke. Nobody dispatching a run needs rights to create
# compute in the account.

# Inlined rather than a lambda/ directory: this stack has to be two files.
data "archive_file" "orchestrator" {
  type        = "zip"
  output_path = "${path.module}/.orchestrator.zip"

  source {
    filename = "orchestrator.py"
    content  = local.orchestrator_py
  }
}

locals {
  orchestrator_py = <<-PYTHON
    """Rig orchestrator — the only thing in the account that calls ecs:RunTask.

    Callers reach this through API Gateway with SigV4, so running a rig needs
    execute-api:Invoke and nothing else. No ECS, no PassRole, no EC2 in the caller's role.

    A rig is two paired tasks (node 0: unreal + px4-sitl + jsbsim, node 1: polaris +
    receiver + uxrce-agent). This owns their lifecycle: place both, tear down as a pair,
    and report status. Half a rig cannot run and still bills a GPU.

      POST /runs           {run_config, px4_build, run_id}  -> place a rig
      GET  /runs/{run_id}                          -> status of both nodes
      DELETE /runs/{run_id}                        -> stop both nodes
    """

    import json
    import os
    import re

    import boto3

    CLUSTER = os.environ["CLUSTER"]
    TASK_FAMILY_UNREAL = os.environ["TASK_FAMILY_UNREAL"]
    TASK_FAMILY_POLARIS = os.environ["TASK_FAMILY_POLARIS"]
    SUBNETS = [s for s in os.environ["SUBNETS"].split(",") if s]
    SECURITY_GROUPS = [s for s in os.environ["SECURITY_GROUPS"].split(",") if s]
    ARTIFACTS_BUCKET = os.environ["ARTIFACTS_BUCKET"]

    NODES = ("unreal", "polaris")
    FAMILIES = {"unreal": TASK_FAMILY_UNREAL, "polaris": TASK_FAMILY_POLARIS}
    # Per-node capacity providers: RunTask must use a capacityProviderStrategy —
    # launchType=EC2 bypasses managed scaling, so a scaled-to-zero cluster would
    # fail with "No Container Instances" instead of scaling out.
    CAPACITY_PROVIDERS = {
        "unreal": os.environ["CP_UNREAL"],
        "polaris": os.environ["CP_POLARIS"],
    }
    # Every container on a node gets the run env; container names are not node names.
    CONTAINERS = {
        "unreal": [c for c in os.environ["CONTAINERS_UNREAL"].split(",") if c],
        "polaris": [c for c in os.environ["CONTAINERS_POLARIS"].split(",") if c],
    }
    # startedBy caps at 36 chars, and it is the lookup key, so run_id is bounded by it.
    RUN_ID_RE = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]{0,35}$")

    ecs = boto3.client("ecs")


    def _reply(status: int, body: dict) -> dict:
        return {"statusCode": status,
                "headers": {"Content-Type": "application/json"},
                "body": json.dumps(body)}


    def _tasks_for(run_id: str) -> list[dict]:
        """Find a rig's tasks by startedBy, which ECS filters server-side.

        Tags would also carry runId, but DescribeTasks only returns them when explicitly
        asked and they cannot be filtered on — every lookup would have to page all tasks in
        the cluster and filter client-side. Node identity comes from the task-definition
        family for the same reason: it is always present, tags are not.
        """
        arns: list[str] = []
        for desired in ("RUNNING", "STOPPED"):
            arns += ecs.list_tasks(cluster=CLUSTER, desiredStatus=desired,
                                   startedBy=run_id)["taskArns"]
        if not arns:
            return []

        by_family = {v: k for k, v in FAMILIES.items()}
        found = []
        for task in ecs.describe_tasks(cluster=CLUSTER, tasks=arns)["tasks"]:
            family = task["taskDefinitionArn"].rsplit("/", 1)[-1].split(":")[0]
            found.append({
                "node": by_family.get(family, family),
                "taskArn": task["taskArn"],
                "lastStatus": task["lastStatus"],
                "stoppedReason": task.get("stoppedReason"),
                "exitCode": (task.get("containers") or [{}])[0].get("exitCode"),
            })
        return found


    def _start(run_id: str, run_config: str, px4_build: str) -> dict:
        env = [
            {"name": "RUN_CONFIG", "value": run_config},
            {"name": "PX4_BUILD", "value": px4_build},
            {"name": "RUN_ID", "value": run_id},
            {"name": "OUTPUT_PREFIX", "value": f"s3://{ARTIFACTS_BUCKET}/runs/{run_id}"},
        ]

        started: dict[str, str] = {}
        for node in NODES:
            resp = ecs.run_task(
                cluster=CLUSTER,
                taskDefinition=FAMILIES[node],
                count=1,
                capacityProviderStrategy=[
                    {"capacityProvider": CAPACITY_PROVIDERS[node], "weight": 1},
                ],
                networkConfiguration={"awsvpcConfiguration": {
                    "subnets": SUBNETS,
                    "securityGroups": SECURITY_GROUPS,
                    "assignPublicIp": "DISABLED",
                }},
                overrides={"containerOverrides": [
                    {"name": name, "environment": env} for name in CONTAINERS[node]
                ]},
                # startedBy is the lookup key; tags are for cost allocation only.
                startedBy=run_id,
                tags=[{"key": "runId", "value": run_id}, {"key": "rigNode", "value": node}],
            )

            # Placement problems are returned, not raised. Tear the pair down rather than
            # leaving one node idling on a paid GPU.
            if resp.get("failures") or not resp.get("tasks"):
                for arn in started.values():
                    ecs.stop_task(cluster=CLUSTER, task=arn, reason="rig placement failed")
                return {"error": f"could not place the {node} task",
                        "failures": resp.get("failures", []),
                        "stopped": list(started.values())}

            started[node] = resp["tasks"][0]["taskArn"]

        return {"runId": run_id,
                "tasks": started,
                "outputPrefix": f"s3://{ARTIFACTS_BUCKET}/runs/{run_id}"}


    def handler(event, _context):
        method = event.get("requestContext", {}).get("http", {}).get("method", "")
        run_id = (event.get("pathParameters") or {}).get("run_id")

        if method == "POST":
            try:
                body = json.loads(event.get("body") or "{}")
            except json.JSONDecodeError:
                return _reply(400, {"error": "body must be JSON"})

            # Only accept objects already staged in our own bucket: a caller cannot point a
            # rig at an arbitrary object it does not have rights to.
            run_config = body.get("run_config") or ""
            px4_build = body.get("px4_build") or ""
            for label, value in (("run_config", run_config), ("px4_build", px4_build)):
                if not value.startswith(f"s3://{ARTIFACTS_BUCKET}/"):
                    return _reply(400, {"error": f"{label} must be an s3:// URI under {ARTIFACTS_BUCKET}"})

            run_id = body.get("run_id") or ""
            if not RUN_ID_RE.match(run_id):
                return _reply(400, {"error": "run_id must match [A-Za-z0-9][A-Za-z0-9._-]{0,35}"})

            if _tasks_for(run_id):
                return _reply(409, {"error": f"run_id {run_id} already exists"})

            result = _start(run_id, run_config, px4_build)
            return _reply(502 if "error" in result else 201, result)

        if not run_id:
            return _reply(400, {"error": "run_id required"})

        if method == "GET":
            tasks = _tasks_for(run_id)
            if not tasks:
                return _reply(404, {"error": f"no tasks for run_id {run_id}"})
            return _reply(200, {"runId": run_id, "nodes": tasks})

        if method == "DELETE":
            tasks = _tasks_for(run_id)
            stopped = [t["taskArn"] for t in tasks if t["lastStatus"] != "STOPPED"]
            for arn in stopped:
                ecs.stop_task(cluster=CLUSTER, task=arn, reason="stopped via rig API")
            return _reply(200, {"runId": run_id, "stopped": stopped})

        return _reply(405, {"error": f"method {method} not allowed"})
  PYTHON
}

# The orchestrator's role and the invoke policy are created by ../polaris-sim-iam, so this
# config makes no IAM roles or policies of its own. That is what keeps the access
# request's "no iam:CreateRole for us" line true.
data "aws_iam_role" "orchestrator" {
  name = "mach-gnc-polaris-sim-orchestrator"
}

resource "aws_lambda_function" "orchestrator" {
  function_name    = "${local.name}-orchestrator"
  role             = data.aws_iam_role.orchestrator.arn
  handler          = "orchestrator.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.orchestrator.output_path
  source_code_hash = data.archive_file.orchestrator.output_base64sha256
  timeout          = 60

  environment {
    variables = {
      CLUSTER             = aws_ecs_cluster.unreal.name
      TASK_FAMILY_UNREAL  = aws_ecs_task_definition.unreal.family
      TASK_FAMILY_POLARIS = aws_ecs_task_definition.polaris.family
      CP_UNREAL           = aws_ecs_capacity_provider.node["unreal"].name
      CP_POLARIS          = aws_ecs_capacity_provider.node["polaris"].name
      CONTAINERS_UNREAL   = "unreal,px4-sitl"
      CONTAINERS_POLARIS  = "polaris-strike,sim-image-receiver,uxrce-agent"
      SUBNETS             = join(",", local.az_subnet_ids)
      SECURITY_GROUPS     = aws_security_group.instances.id
      ARTIFACTS_BUCKET    = var.artifacts_bucket
    }
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "orchestrator" {
  name              = "/aws/lambda/${local.name}-orchestrator"
  retention_in_days = 30
  tags              = local.tags
}

# ----------------------------------------------------------
# HTTP API with IAM auth — callers sign with SigV4
# ----------------------------------------------------------

resource "aws_apigatewayv2_api" "rig" {
  name          = "${local.name}-api"
  protocol_type = "HTTP"
  tags          = local.tags
}

resource "aws_apigatewayv2_integration" "orchestrator" {
  api_id                 = aws_apigatewayv2_api.rig.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.orchestrator.invoke_arn
  payload_format_version = "2.0"
}

locals {
  api_routes = [
    "POST /runs",
    "GET /runs/{run_id}",
    "DELETE /runs/{run_id}",
  ]
}

resource "aws_apigatewayv2_route" "rig" {
  for_each = toset(local.api_routes)

  api_id             = aws_apigatewayv2_api.rig.id
  route_key          = each.value
  target             = "integrations/${aws_apigatewayv2_integration.orchestrator.id}"
  authorization_type = "AWS_IAM"
}

resource "aws_apigatewayv2_stage" "rig" {
  api_id      = aws_apigatewayv2_api.rig.id
  name        = "$default"
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api.arn
    format = jsonencode({
      requestId = "$context.requestId"
      caller    = "$context.identity.caller"
      route     = "$context.routeKey"
      status    = "$context.status"
      error     = "$context.error.message"
    })
  }

  tags = local.tags
}

resource "aws_cloudwatch_log_group" "api" {
  name              = "/aws/apigateway/${local.name}"
  retention_in_days = 30
  tags              = local.tags
}

resource "aws_lambda_permission" "api" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.orchestrator.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.rig.execution_arn}/*/*"
}


data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}
