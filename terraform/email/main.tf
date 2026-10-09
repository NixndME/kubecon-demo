# Email for the demo: SES sends from noreply@<domain>, signed with DKIM. SES stays in test mode
# (sandbox): it only sends to addresses that confirmed a mail from Amazon, up to 200 a day.
# The sender user only sends mail and asks Amazon to confirm new addresses. Its key is made by
# scripts/setup-email.sh and kept outside the repo.

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

variable "region" {
  type    = string
  default = "us-west-2"
}

variable "project_tag" {
  type    = string
  default = "kubecon-demo"
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

data "aws_caller_identity" "me" {}

data "aws_route53_zone" "public" {
  name = var.domain
}

resource "aws_sesv2_email_identity" "domain" {
  email_identity = var.domain
  tags = {
    Name = "${var.project_tag}-mail-domain"
  }
}

# DKIM: three CNAMEs prove the domain is ours and sign every mail
resource "aws_route53_record" "dkim" {
  count   = 3
  zone_id = data.aws_route53_zone.public.zone_id
  name    = "${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}._domainkey.${var.domain}"
  type    = "CNAME"
  ttl     = 600
  records = ["${aws_sesv2_email_identity.domain.dkim_signing_attributes[0].tokens[count.index]}.dkim.amazonses.com"]
}

# Mail providers trust signed mail more with a DMARC record
resource "aws_route53_record" "dmarc" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = "_dmarc.${var.domain}"
  type    = "TXT"
  ttl     = 600
  records = ["v=DMARC1; p=none"]
}

resource "aws_iam_user" "mailer" {
  name = "${var.project_tag}-mailer"
  tags = {
    Name = "${var.project_tag}-mailer"
  }
}

resource "aws_iam_user_policy" "mailer" {
  name = "send-mail"
  user = aws_iam_user.mailer.name
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = ["ses:SendEmail", "ses:SendRawEmail", "ses:GetEmailIdentity", "ses:CreateEmailIdentity", "ses:TagResource"]
      Resource = "arn:aws:ses:${var.region}:${data.aws_caller_identity.me.account_id}:identity/*"
    }]
  })
}

output "mailer_user" {
  value = aws_iam_user.mailer.name
}

output "dkim_status" {
  value = aws_sesv2_email_identity.domain.dkim_signing_attributes[0].status
}
