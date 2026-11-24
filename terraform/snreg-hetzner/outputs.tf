output "url" {
  description = "Where users and agents reach SNReg"
  value       = local.url
}
output "ipv4" { value = hcloud_server.snreg.ipv4_address }
output "wireguard_endpoint" { value = "${local.fqdn}:51820" }
