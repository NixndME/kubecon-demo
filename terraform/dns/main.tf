# Public DNS zone for the demo domain. Kept apart from the lab so a rebuild never changes the name servers.

terraform {
  required_version = ">= 1.6"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
  # State lives outside the repo: terraform init -backend-config="path=<state file>"
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

provider "aws" {
  region  = "us-east-1"
  profile = var.aws_profile
  default_tags {
    tags = {
      Project = var.project_tag
    }
  }
}

resource "aws_route53_zone" "public" {
  name          = var.domain
  comment       = "Public zone for the ${var.project_tag} lab"
  force_destroy = false
  tags = {
    Name = "${var.project_tag}-public-zone"
  }
}

output "zone_id" {
  value = aws_route53_zone.public.zone_id
}

output "name_servers" {
  value = aws_route53_zone.public.name_servers
}
