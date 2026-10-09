output "vpc_id" {
  value = aws_vpc.main.id
}

output "mgmt_subnet_id" {
  value = aws_subnet.mgmt.id
}

output "hks_subnet_id" {
  value = aws_subnet.hks.id
}

output "mgmt_sg_id" {
  value = aws_security_group.mgmt.id
}

output "morpheus_eip" {
  value = aws_eip.morpheus.public_ip
}

output "morpheus_fqdn" {
  value = aws_route53_record.morpheus.fqdn
}

output "private_zone_id" {
  value = aws_route53_zone.private.zone_id
}
