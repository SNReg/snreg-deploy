output "url" {
  description = "Where users and agents reach SNReg"
  value       = local.url
}
output "public_ip" { value = aws_eip.snreg.public_ip }
output "wireguard_endpoint" { value = "${local.fqdn}:51820" }
