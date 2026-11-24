# Terraform modules

One SNReg instance per customer for the hosted tier (spec §8). Each installs the server package
through cloud-init (the systemd path) and outputs `url`.

- `snreg-hetzner`: a Hetzner Cloud VM with PostgreSQL on it, a firewall, and an A record in a
  Hetzner DNS zone (`HCLOUD_TOKEN`, `HETZNER_DNS_API_TOKEN`).
- `snreg-aws`: an EC2 VM, RDS PostgreSQL 16 reachable only from it, an Elastic IP and a Route 53
  record.

The first admin's password is in `/var/log/snreg-init.log` on the VM. The certificate is
self-signed until you install a real one; agents pin whichever is in place when they enroll.
`terraform validate` runs in CI; neither module is applied there.
