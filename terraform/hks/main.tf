# HKS nodes: one master and one GPU worker. Morpheus builds the cluster on them over SSH.

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

# Find the network by its tags

data "aws_vpc" "main" {
  tags = { Name = "${local.p}-vpc", Project = local.p }
}

data "aws_subnet" "hks" {
  tags = { Name = "${local.p}-hks", Project = local.p }
}

data "aws_security_group" "mgmt" {
  tags = { Name = "${local.p}-mgmt-sg", Project = local.p }
}

data "aws_route53_zone" "public" {
  name         = var.domain
  private_zone = false
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

# Security group: nodes talk freely to each other, Morpheus and the admin IPs get what they need

resource "aws_security_group" "hks" {
  name        = "${local.p}-hks-sg"
  description = "HKS nodes"
  vpc_id      = data.aws_vpc.main.id
  tags        = { Name = "${local.p}-hks-sg" }
}

resource "aws_vpc_security_group_ingress_rule" "hks_self" {
  security_group_id            = aws_security_group.hks.id
  description                  = "Node to node"
  referenced_security_group_id = aws_security_group.hks.id
  ip_protocol                  = "-1"
  tags                         = { Name = "${local.p}-hks-self" }
}

resource "aws_vpc_security_group_ingress_rule" "hks_from_morpheus" {
  for_each                     = { ssh = 22, api = 6443 }
  security_group_id            = aws_security_group.hks.id
  description                  = "Morpheus ${each.key}"
  referenced_security_group_id = data.aws_security_group.mgmt.id
  ip_protocol                  = "tcp"
  from_port                    = each.value
  to_port                      = each.value
  tags                         = { Name = "${local.p}-hks-morpheus-${each.key}" }
}

locals {
  admin_ports = { ssh = [22, 22], api = [6443, 6443], nodeports = [30000, 32767] }
  admin_rules = { for pair in setproduct(keys(local.admin_ports), var.admin_cidrs) : "${pair[0]}-${pair[1]}" => { port = local.admin_ports[pair[0]], cidr = pair[1], name = pair[0] } }
}

resource "aws_vpc_security_group_ingress_rule" "hks_admin" {
  for_each          = local.admin_rules
  security_group_id = aws_security_group.hks.id
  description       = "Admin ${each.value.name}"
  cidr_ipv4         = each.value.cidr
  ip_protocol       = "tcp"
  from_port         = each.value.port[0]
  to_port           = each.value.port[1]
  tags              = { Name = "${local.p}-hks-admin-${each.value.name}" }
}

# Web traffic from anywhere: apps are reached through Traefik, every page asks for a login
resource "aws_vpc_security_group_ingress_rule" "hks_web" {
  for_each          = { http = 80, https = 443 }
  security_group_id = aws_security_group.hks.id
  description       = "Web ${each.key} from anywhere"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "tcp"
  from_port         = each.value
  to_port           = each.value
  tags              = { Name = "${local.p}-hks-web-${each.key}" }
}

resource "aws_vpc_security_group_egress_rule" "hks_all" {
  security_group_id = aws_security_group.hks.id
  description       = "All outbound"
  cidr_ipv4         = "0.0.0.0/0"
  ip_protocol       = "-1"
  tags              = { Name = "${local.p}-hks-out" }
}

# Nodes

resource "aws_instance" "node" {
  for_each = var.nodes

  ami                     = data.aws_ssm_parameter.ubuntu.value
  instance_type           = each.value.type
  subnet_id               = data.aws_subnet.hks.id
  private_ip              = each.value.ip
  vpc_security_group_ids  = [aws_security_group.hks.id]
  key_name                = var.key_name
  disable_api_termination = var.protect

  # Calico sends pod traffic between nodes in the same subnet without a tunnel; AWS drops it unless this is off
  source_dest_check = false

  metadata_options {
    http_tokens = "required"
  }

  root_block_device {
    volume_type           = "gp3"
    volume_size           = each.value.root_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = { Name = "${local.p}-${each.key}-root", Project = local.p }
  }

  # Data disk for container storage, the Data Device in the Morpheus cluster wizard
  ebs_block_device {
    device_name           = "/dev/sdf"
    volume_type           = "gp3"
    volume_size           = each.value.data_gb
    encrypted             = true
    delete_on_termination = true
    tags                  = { Name = "${local.p}-${each.key}-data", Project = local.p }
  }

  user_data = <<-EOF
    #cloud-config
    hostname: ${each.key}
    ssh_pwauth: true
    users:
      - default
      - name: ${var.node_user}
        groups: sudo
        shell: /bin/bash
        sudo: ALL=(ALL) NOPASSWD:ALL
        lock_passwd: false
        passwd: ${var.node_password_hash}
        ssh_authorized_keys:
          - ${trimspace(file(pathexpand(var.public_key_path)))}
    # Same name for the data disk on every node: /dev/hks-data (NVMe names change between machines)
    write_files:
      - path: /etc/udev/rules.d/90-hks-data.rules
        content: |
          KERNEL=="nvme*n1", ATTRS{model}=="Amazon Elastic Block Store*", ATTR{size}=="${each.value.data_gb * 2097152}", SYMLINK+="hks-data"
    runcmd:
      - udevadm control --reload
      - udevadm trigger --subsystem-match=block
    package_update: true
    packages:
      - chrony
      - curl
      - lvm2
  EOF

  tags = { Name = "${local.p}-${each.key}", Role = each.value.role }

  lifecycle {
    ignore_changes = [ami, user_data]
  }
}

# AWS does not copy instance tags to its network interface
resource "aws_ec2_tag" "eni" {
  for_each    = { for pair in setproduct(keys(var.nodes), ["Project", "Name"]) : "${pair[0]}-${pair[1]}" => { node = pair[0], key = pair[1] } }
  resource_id = aws_instance.node[each.value.node].primary_network_interface_id
  key         = each.value.key
  value       = each.value.key == "Project" ? local.p : "${local.p}-${each.value.node}-eni"
}

# Fixed public IPs and names

resource "aws_eip" "node" {
  for_each = var.nodes
  domain   = "vpc"
  tags     = { Name = "${local.p}-${each.key}-eip" }
}

resource "aws_eip_association" "node" {
  for_each      = var.nodes
  instance_id   = aws_instance.node[each.key].id
  allocation_id = aws_eip.node[each.key].id
}

resource "aws_route53_record" "public" {
  for_each = var.nodes
  zone_id  = data.aws_route53_zone.public.zone_id
  name     = "${each.value.dns}.${var.domain}"
  type     = "A"
  ttl      = 300
  records  = [aws_eip.node[each.key].public_ip]
}

# Inside the VPC the same names point at the private IPs
resource "aws_route53_record" "private" {
  for_each = var.nodes
  zone_id  = data.aws_route53_zone.private.zone_id
  name     = "${each.value.dns}.${var.domain}"
  type     = "A"
  ttl      = 300
  records  = [each.value.ip]
}

output "nodes" {
  value = { for k, v in aws_instance.node : k => {
    id         = v.id
    type       = v.instance_type
    private_ip = v.private_ip
    public_ip  = aws_eip.node[k].public_ip
    name       = aws_route53_record.public[k].fqdn
  } }
}
