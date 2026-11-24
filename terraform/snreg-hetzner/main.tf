# SNReg on Hetzner Cloud (spec §8): one VM running the server package and PostgreSQL, a firewall,
# and an A record in a Hetzner DNS zone. The first admin's password is in the VM's
# /var/log/snreg-init.log (root only); log in and change it.
terraform {
  required_version = ">= 1.6"
  required_providers {
    hcloud     = { source = "hetznercloud/hcloud", version = "~> 1.49" }
    hetznerdns = { source = "timohirt/hetznerdns", version = "~> 2.2" }
  }
}

data "hetznerdns_zone" "this" { name = var.dns_zone }

resource "hcloud_firewall" "snreg" {
  name = "${var.name}-snreg"
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "22"
    source_ips = var.ssh_source_ips
  }
  rule {
    direction  = "in"
    protocol   = "tcp"
    port       = "8443"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
  rule {
    direction  = "in"
    protocol   = "udp"
    port       = "51820"
    source_ips = ["0.0.0.0/0", "::/0"]
  }
}

resource "hcloud_server" "snreg" {
  name         = var.name
  server_type  = var.server_type
  location     = var.location
  image        = "debian-12"
  ssh_keys     = var.ssh_keys
  firewall_ids = [hcloud_firewall.snreg.id]
  user_data = templatefile("${path.module}/cloud-init.yaml", {
    package_url = var.server_package_url
    public_url  = local.url
  })
}

resource "hetznerdns_record" "snreg" {
  zone_id = data.hetznerdns_zone.this.id
  name    = var.name
  type    = "A"
  value   = hcloud_server.snreg.ipv4_address
  ttl     = 300
}

locals {
  fqdn = "${var.name}.${var.dns_zone}"
  url  = "https://${local.fqdn}:8443"
}
