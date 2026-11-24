# SNReg on AWS (spec §8): an EC2 VM running the server package, a managed PostgreSQL 16 (RDS) only
# that VM can reach, and a Route 53 record. The first admin's password is in the VM's
# /var/log/snreg-init.log (root only); log in and change it.
terraform {
  required_version = ">= 1.6"
  required_providers {
    aws    = { source = "hashicorp/aws", version = "~> 5.0" }
    random = { source = "hashicorp/random", version = "~> 3.6" }
  }
}

data "aws_route53_zone" "this" { zone_id = var.route53_zone_id }

data "aws_ami" "debian" {
  most_recent = true
  owners      = ["136693071363"] # Debian
  filter {
    name   = "name"
    values = ["debian-12-amd64-*"]
  }
}

resource "aws_security_group" "server" {
  name   = "${var.name}-snreg-server"
  vpc_id = var.vpc_id
  ingress {
    from_port   = 22
    to_port     = 22
    protocol    = "tcp"
    cidr_blocks = var.ssh_source_cidrs
  }
  ingress {
    from_port   = 8443
    to_port     = 8443
    protocol    = "tcp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  ingress {
    from_port   = 51820
    to_port     = 51820
    protocol    = "udp"
    cidr_blocks = ["0.0.0.0/0"]
  }
  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }
}

resource "aws_security_group" "db" {
  name   = "${var.name}-snreg-db"
  vpc_id = var.vpc_id
  ingress {
    from_port       = 5432
    to_port         = 5432
    protocol        = "tcp"
    security_groups = [aws_security_group.server.id]
  }
}

resource "aws_db_subnet_group" "snreg" {
  name       = "${var.name}-snreg"
  subnet_ids = var.db_subnet_ids
}

resource "random_password" "db" {
  length  = 32
  special = false
}

resource "aws_db_instance" "snreg" {
  identifier                = "${var.name}-snreg"
  engine                    = "postgres"
  engine_version            = "16"
  instance_class            = var.db_instance_class
  allocated_storage         = 20
  storage_encrypted         = true
  db_name                   = "snreg"
  username                  = "snreg"
  password                  = random_password.db.result
  db_subnet_group_name      = aws_db_subnet_group.snreg.name
  vpc_security_group_ids    = [aws_security_group.db.id]
  backup_retention_period   = 7
  deletion_protection       = true
  final_snapshot_identifier = "${var.name}-snreg-final"
}

resource "aws_instance" "snreg" {
  ami                    = data.aws_ami.debian.id
  instance_type          = var.instance_type
  subnet_id              = var.server_subnet_id
  key_name               = var.key_name
  vpc_security_group_ids = [aws_security_group.server.id]
  # IMDSv2 only, and not reachable from containers: user_data holds the database password.
  metadata_options {
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
  }
  root_block_device { encrypted = true }
  user_data = templatefile("${path.module}/cloud-init.yaml", {
    package_url  = var.server_package_url
    public_url   = local.url
    database_url = "postgres://snreg:${random_password.db.result}@${aws_db_instance.snreg.address}:5432/snreg"
  })
}

resource "aws_eip" "snreg" { instance = aws_instance.snreg.id }

resource "aws_route53_record" "snreg" {
  zone_id = var.route53_zone_id
  name    = local.fqdn
  type    = "A"
  ttl     = 300
  records = [aws_eip.snreg.public_ip]
}

locals {
  fqdn = "${var.name}.${trimsuffix(data.aws_route53_zone.this.name, ".")}"
  url  = "https://${local.fqdn}:8443"
}
