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

variable "az" {
  type    = string
  default = "us-west-2a"
}

variable "vpc_cidr" {
  type    = string
  default = "10.50.0.0/16"
}

variable "mgmt_cidr" {
  type    = string
  default = "10.50.1.0/24"
}

variable "hks_cidr" {
  type    = string
  default = "10.50.10.0/24"
}

# Laptop / venue IPs allowed in, e.g. ["203.0.113.10/32"]
variable "admin_cidrs" {
  type = list(string)
}

variable "key_name" {
  type    = string
  default = "kubecon-key"
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/kubecon-key.pub"
}
