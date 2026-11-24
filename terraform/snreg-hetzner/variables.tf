variable "name" {
  description = "Server name and DNS label, e.g. acme (gives acme.<dns_zone>)"
  type        = string
}
variable "dns_zone" {
  description = "A Hetzner DNS zone you own, e.g. snreg.example.org"
  type        = string
}
variable "server_package_url" {
  description = "HTTPS URL of the snreg-server .deb (a release asset)"
  type        = string
}
variable "ssh_keys" {
  description = "Hetzner SSH key names or IDs for root"
  type        = list(string)
}
variable "ssh_source_ips" {
  description = "CIDRs allowed to reach SSH"
  type        = list(string)
}
variable "server_type" {
  type    = string
  default = "cx32"
}
variable "location" {
  type    = string
  default = "fsn1"
}
