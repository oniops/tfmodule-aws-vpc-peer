locals {
  # Name tag source. fullname (when set) replaces the derived name verbatim so that the
  # tag can spell out the requester -> accepter direction; otherwise the default rule
  # <name_prefix>-<name>-pcx applies (ARCHITECTURE.md 4, DECISION D-009).
  # This is the only naming expression of the module: no resource address or for_each
  # key derives from it, so setting or clearing fullname only updates the tag in place.
  name = var.fullname != null ? var.fullname : "${var.context.name_prefix}-${var.name}-pcx"

  # Tag merge order: context.tags -> caller custom tags -> module generated Name.
  # Name is merged last so that the merge order itself protects it (ARCHITECTURE.md 5.1, DECISION D-004).
  tags = merge(var.context.tags, var.tags, { Name = local.name })
}

#####################################################################
# Accepter identity/region derivation
#
# account_id and region are values the aws.accepter provider already knows,
# so when the input is omitted (null) they are read from the provider, and
# when the input is set they are checked against the provider's real values.
# This keeps the caller from maintaining the same value in both the provider
# block and the module input (REQUIREMENTS.md 4.3, DECISION D-002/D-003).
#####################################################################

data "aws_caller_identity" "accepter" {
  provider = aws.accepter

  lifecycle {
    postcondition {
      condition     = var.accepter.account_id == null || var.accepter.account_id == self.account_id
      error_message = "accepter.account_id (${coalesce(var.accepter.account_id, "null")}) does not match the AWS account assumed by the aws.accepter provider (${self.account_id})."
    }
  }
}

data "aws_region" "accepter" {
  provider = aws.accepter

  lifecycle {
    postcondition {
      # aws provider v6 deprecates data.aws_region.name in favour of
      # data.aws_region.region, so the current attribute is used to keep plan
      # output free of deprecation warnings (REQUIREMENTS.md 4.3, 7 row 12).
      condition     = var.accepter.region == null || var.accepter.region == self.region
      error_message = "accepter.region (${coalesce(var.accepter.region, "null")}) does not match the region of the aws.accepter provider (${self.region})."
    }
  }
}

locals {
  accepter_account_id = coalesce(var.accepter.account_id, data.aws_caller_identity.accepter.account_id)
  accepter_region     = coalesce(var.accepter.region, data.aws_region.accepter.region)
}

#####################################################################
# VPC Peering Connection
#####################################################################

# Requester side. The request is created in the default `aws` provider.
resource "aws_vpc_peering_connection" "this" {
  vpc_id        = var.requester.vpc_id
  peer_vpc_id   = var.accepter.vpc_id
  peer_owner_id = local.accepter_account_id
  peer_region   = local.accepter_region

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
