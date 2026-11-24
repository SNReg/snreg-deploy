variable "name" {
  description = "Instance name and DNS label, e.g. acme (gives acme.<zone>)"
  type        = string
}
variable "route53_zone_id" {
  description = "A Route 53 hosted zone you own"
  type        = string
}
variable "server_package_url" {
  description = "HTTPS URL of the snreg-server .deb (a release asset)"
  type        = string
}
variable "vpc_id" { type = string }
variable "server_subnet_id" {
  description = "A public subnet for the VM"
  type        = string
}
variable "db_subnet_ids" {
  description = "At least two private subnets in different AZs for RDS"
  type        = list(string)
}
variable "key_name" {
  description = "EC2 key pair for SSH"
  type        = string
}
variable "ssh_source_cidrs" {
  description = "CIDRs allowed to reach SSH"
  type        = list(string)
}
variable "instance_type" {
  type    = string
  default = "t3.medium"
}
variable "db_instance_class" {
  type    = string
  default = "db.t4g.small"
}
