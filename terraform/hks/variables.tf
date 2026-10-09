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

variable "key_name" {
  type    = string
  default = "kubecon-key"
}

variable "public_key_path" {
  type    = string
  default = "~/.ssh/kubecon-key.pub"
}

# Laptop / venue IPs allowed in, e.g. ["203.0.113.10/32"]
variable "admin_cidrs" {
  type = list(string)
}

# Login Morpheus uses to build the cluster
variable "node_user" {
  type = string
}

# SHA-512 hash, make one with: openssl passwd -6
variable "node_password_hash" {
  type      = string
  sensitive = true
}

# Set to false before a destroy
variable "protect" {
  type    = bool
  default = true
}

variable "nodes" {
  type = map(object({
    role    = string
    type    = string
    ip      = string
    root_gb = number
    data_gb = number
    dns     = string
  }))
  default = {
    hks-master = { role = "master", type = "m6a.large", ip = "10.50.10.10", root_gb = 40, data_gb = 50, dns = "k8s" }
    hks-gpu-1  = { role = "gpu-worker", type = "g4dn.2xlarge", ip = "10.50.10.31", root_gb = 60, data_gb = 150, dns = "*" }
  }
}
