locals {
  name = "${var.context.name_prefix}-${var.name}-pcx"

  # Tag merge order: context.tags -> module tags (Name) -> custom tags
  tags = merge(var.context.tags, { Name = local.name }, var.tags)
}

#####################################################################
# VPC Peering Connection
#####################################################################

# Requester side. The request is created in the default `aws` provider.
resource "aws_vpc_peering_connection" "this" {
  vpc_id        = var.requester.vpc_id
  peer_vpc_id   = var.accepter.vpc_id
  peer_owner_id = var.accepter.account_id
  peer_region   = var.accepter.region

  tags = local.tags
}

# Accepter side. The request is accepted in the `aws.accepter` provider.
# Its id equals the peering connection id, so referencing it makes a resource wait for the ACTIVE state.
resource "aws_vpc_peering_connection_accepter" "this" {
  provider                  = aws.accepter
  vpc_peering_connection_id = aws_vpc_peering_connection.this.id
  auto_accept               = true

  tags = local.tags
}

#####################################################################
# DNS Resolution Options
#####################################################################

resource "aws_vpc_peering_connection_options" "requester" {
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  requester {
    allow_remote_vpc_dns_resolution = var.requester.allow_remote_vpc_dns_resolution
  }
}

resource "aws_vpc_peering_connection_options" "accepter" {
  provider                  = aws.accepter
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  accepter {
    allow_remote_vpc_dns_resolution = var.accepter.allow_remote_vpc_dns_resolution
  }
}
