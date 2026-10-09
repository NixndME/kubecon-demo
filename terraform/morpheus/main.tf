# Morpheus appliance VM. Morpheus itself is installed afterwards with scripts/install-morpheus.sh.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  backend "local" {}
}

variable "domain" {
  type = string
}

variable "aws_profile" {
  type    = string
  default = "kubecon-demo"
}

variable "project_tag" {
  type    = string
  default = "kubecon-demo"
}

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "instance_type" {
  type    = string
  default = "r6a.xlarge"
}

variable "disk_gb" {
  type    = number
  default = 150
}

variable "key_name" {
  type    = string
  default = "kubecon-key"
}

# Set to false before a destroy
variable "protect" {
  type    = bool
  default = true
}

provider "aws" {
  region  = var.region
  profile = var.aws_profile
  default_tags {
    tags = {
      Project = var.project_tag
    }
  }
}

locals {
  p    = var.project_tag
  fqdn = "morpheus.${var.domain}"
}

# Find the network by its tags

data "aws_vpc" "main" {
  tags = { Name = "${local.p}-vpc", Project = local.p }
}

data "aws_subnet" "mgmt" {
  tags = { Name = "${local.p}-mgmt", Project = local.p }
}

data "aws_security_group" "mgmt" {
  tags = { Name = "${local.p}-mgmt-sg", Project = local.p }
}

data "aws_eip" "morpheus" {
  tags = { Name = "${local.p}-morpheus-eip", Project = local.p }
}

data "aws_route53_zone" "private" {
  name         = var.domain
  private_zone = true
  vpc_id       = data.aws_vpc.main.id
}

# Latest official Ubuntu 24.04 image from Canonical
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "morpheus" {
  ami                     = data.aws_ssm_parameter.ubuntu.value
  instance_type           = var.instance_type
  subnet_id               = data.aws_subnet.mgmt.id
  vpc_security_group_ids  = [data.aws_security_group.mgmt.id]
  key_name                = var.key_name
  disable_api_termination = var.protect

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = var.disk_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = { Name = "${local.p}-morpheus-root", Project = local.p }
  }

  user_data = <<-EOF
    #cloud-config
    hostname: morpheus
    fqdn: ${local.fqdn}
    prefer_fqdn_over_hostname: true
    swap:
      filename: /swapfile
      size: 8G
    package_update: true
    packages:
      - chrony
      - curl
      - lsof
  EOF

  tags = { Name = "${local.p}-morpheus" }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# AWS does not copy instance tags to its network interface
resource "aws_ec2_tag" "morpheus_eni" {
  for_each    = { Project = local.p, Name = "${local.p}-morpheus-eni" }
  resource_id = aws_instance.morpheus.primary_network_interface_id
  key         = each.key
  value       = each.value
}

resource "aws_eip_association" "morpheus" {
  instance_id   = aws_instance.morpheus.id
  allocation_id = data.aws_eip.morpheus.id
}

# Inside the VPC the name points at the private IP
resource "aws_route53_record" "private" {
  zone_id = data.aws_route53_zone.private.zone_id
  name    = local.fqdn
  type    = "A"
  ttl     = 300
  records = [aws_instance.morpheus.private_ip]
}

output "instance_id" {
  value = aws_instance.morpheus.id
}

output "private_ip" {
  value = aws_instance.morpheus.private_ip
}

output "url" {
  value = "https://${local.fqdn}"
}

output "ssh" {
  value = "ssh -i ~/.ssh/kubecon-key ubuntu@${local.fqdn}"
}
