# Small Ubuntu VM to test the network, SSH key and DNS name before Morpheus is built.

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
  default = "t3.micro"
}

variable "key_name" {
  type    = string
  default = "kubecon-key"
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
  p = var.project_tag
}

# Find the network by its tags

data "aws_subnet" "mgmt" {
  tags = { Name = "${local.p}-mgmt", Project = local.p }
}

data "aws_security_group" "mgmt" {
  tags = { Name = "${local.p}-mgmt-sg", Project = local.p }
}

data "aws_eip" "morpheus" {
  tags = { Name = "${local.p}-morpheus-eip", Project = local.p }
}

# Latest official Ubuntu 24.04 image from Canonical
data "aws_ssm_parameter" "ubuntu" {
  name = "/aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id"
}

resource "aws_instance" "test" {
  ami                    = data.aws_ssm_parameter.ubuntu.value
  instance_type          = var.instance_type
  subnet_id              = data.aws_subnet.mgmt.id
  vpc_security_group_ids = [data.aws_security_group.mgmt.id]
  key_name               = var.key_name

  # No surprise CPU credit charges
  credit_specification {
    cpu_credits = "standard"
  }

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type = "gp3"
    volume_size = 20
    encrypted   = true
    tags        = { Name = "${local.p}-test-root", Project = local.p }
  }

  user_data = <<-EOF
    #cloud-config
    hostname: ${local.p}-test
  EOF

  tags = { Name = "${local.p}-test" }

  lifecycle {
    ignore_changes = [ami]
  }
}

# AWS does not copy instance tags to its network interface
resource "aws_ec2_tag" "test_eni" {
  for_each    = { Project = local.p, Name = "${local.p}-test-eni" }
  resource_id = aws_instance.test.primary_network_interface_id
  key         = each.key
  value       = each.value
}

resource "aws_eip_association" "test" {
  instance_id   = aws_instance.test.id
  allocation_id = data.aws_eip.morpheus.id
}

output "instance_id" {
  value = aws_instance.test.id
}

output "ssh" {
  value = "ssh -i ~/.ssh/kubecon-key ubuntu@morpheus.${var.domain}"
}
