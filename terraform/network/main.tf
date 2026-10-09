# Lab network: VPC, two public subnets, internet gateway, security group, key pair, Elastic IP and DNS name.

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

# VPC and internet access

resource "aws_vpc" "main" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true
  tags                 = { Name = "${local.p}-vpc" }
}

resource "aws_internet_gateway" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.p}-igw" }
}

resource "aws_subnet" "mgmt" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.mgmt_cidr
  availability_zone       = var.az
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.p}-mgmt" }
}

# HKS nodes get a public IP so they reach the internet without a NAT gateway
resource "aws_subnet" "hks" {
  vpc_id                  = aws_vpc.main.id
  cidr_block              = var.hks_cidr
  availability_zone       = var.az
  map_public_ip_on_launch = true
  tags                    = { Name = "${local.p}-hks" }
}

resource "aws_route_table" "public" {
  vpc_id = aws_vpc.main.id
  route {
    cidr_block = "0.0.0.0/0"
    gateway_id = aws_internet_gateway.main.id
  }
  tags = { Name = "${local.p}-public-rt" }
}

resource "aws_route_table_association" "mgmt" {
  subnet_id      = aws_subnet.mgmt.id
  route_table_id = aws_route_table.public.id
}

resource "aws_route_table_association" "hks" {
  subnet_id      = aws_subnet.hks.id
  route_table_id = aws_route_table.public.id
}

# The pieces AWS makes with every VPC, managed here so they carry our tags

resource "aws_default_route_table" "main" {
  default_route_table_id = aws_vpc.main.default_route_table_id
  tags                   = { Name = "${local.p}-default-rt" }
}

resource "aws_default_network_acl" "main" {
  default_network_acl_id = aws_vpc.main.default_network_acl_id
  subnet_ids             = [aws_subnet.mgmt.id, aws_subnet.hks.id]

  ingress {
    protocol   = -1
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }
  egress {
    protocol   = -1
    rule_no    = 100
    action     = "allow"
    cidr_block = "0.0.0.0/0"
    from_port  = 0
    to_port    = 0
  }
  tags = { Name = "${local.p}-default-nacl" }
}

# No rules: nothing should use the default security group
resource "aws_default_security_group" "main" {
  vpc_id = aws_vpc.main.id
  tags   = { Name = "${local.p}-default-sg" }
}

# Morpheus: SSH from the admin IPs, HTTPS from anywhere

resource "aws_security_group" "mgmt" {
  name        = "${local.p}-mgmt-sg"
  description = "Morpheus appliance"
  vpc_id      = aws_vpc.main.id
  tags        = { Name = "${local.p}-mgmt-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "mgmt_ssh" {
  for_each          = toset(var.admin_cidrs)
  security_group_id = aws_security_group.mgmt.id
  description       = "SSH from admin"
  cidr_ipv4         = each.value
  ip_protocol       = "tcp"
  from_port         = 22
  to_port           = 22
  tags              = { Name = "${local.p}-mgmt-ssh" }
}

# Morpheus web page from anywhere, it has its own login
resource "aws_vpc_security_group_ingress_rule" "mgmt_https" {
  security_group_id = aws_security_group.mgmt.id
  description       = "HTTPS from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  tags              = { Name = "${local.p}-mgmt-https" }
}

resource "aws_vpc_security_group_ingress_rule" "mgmt_https_vpc" {
  security_group_id = aws_security_group.mgmt.id
  description       = "HTTPS from the lab nodes"
  cidr_ipv4         = var.vpc_cidr
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  tags              = { Name = "${local.p}-mgmt-https-vpc" }
}

resource "aws_vpc_security_group_egress_rule" "mgmt_all" {
  security_group_id = aws_security_group.mgmt.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  tags              = { Name = "${local.p}-mgmt-out" }
}

# SSH key (public half only, the private key stays on the laptop)

resource "aws_key_pair" "lab" {
  key_name   = var.key_name
  public_key = file(pathexpand(var.public_key_path))
  tags       = { Name = var.key_name }
}

# Fixed public IP and name for Morpheus; the test VM borrows it first

resource "aws_eip" "morpheus" {
  domain = "vpc"
  tags   = { Name = "${local.p}-morpheus-eip" }
}

data "aws_route53_zone" "public" {
  name         = var.domain
  private_zone = false
}

resource "aws_route53_record" "morpheus" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = "morpheus.${var.domain}"
  type    = "A"
  ttl     = 300
  records = [aws_eip.morpheus.public_ip]
}

# Same domain inside the VPC only, so lab nodes reach Morpheus on its private IP
resource "aws_route53_zone" "private" {
  name    = var.domain
  comment = "Private zone for the ${local.p} VPC"
  vpc {
    vpc_id = aws_vpc.main.id
  }
  tags = { Name = "${local.p}-private-zone" }
}
