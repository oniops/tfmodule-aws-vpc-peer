#####################################################################
# Route53 Private Hosted Zone Association
#
# A private hosted zone owned by one side is associated with the VPC of the other side.
# The zone owner authorizes the association, then the VPC owner associates the zone.
#####################################################################

# Accepter zone -> requester VPC
data "aws_route53_zone" "accepter" {
  count    = var.accepter.private_domain != null ? 1 : 0
  provider = aws.accepter

  name         = var.accepter.private_domain
  private_zone = true
  vpc_id       = var.accepter.vpc_id
}

resource "aws_route53_vpc_association_authorization" "accepter" {
  count    = var.accepter.private_domain != null ? 1 : 0
  provider = aws.accepter

  zone_id    = data.aws_route53_zone.accepter[0].zone_id
  vpc_id     = var.requester.vpc_id
  vpc_region = var.context.region

  depends_on = [aws_vpc_peering_connection_accepter.this]
}

resource "aws_route53_zone_association" "accepter" {
  count = var.accepter.private_domain != null ? 1 : 0

  zone_id    = data.aws_route53_zone.accepter[0].zone_id
  vpc_id     = var.requester.vpc_id
  vpc_region = var.context.region

  depends_on = [aws_route53_vpc_association_authorization.accepter]
}

# Requester zone -> accepter VPC
data "aws_route53_zone" "requester" {
  count = var.requester.private_domain != null ? 1 : 0

  name         = var.requester.private_domain
  private_zone = true
  vpc_id       = var.requester.vpc_id
}

resource "aws_route53_vpc_association_authorization" "requester" {
  count = var.requester.private_domain != null ? 1 : 0

  zone_id    = data.aws_route53_zone.requester[0].zone_id
  vpc_id     = var.accepter.vpc_id
  vpc_region = local.accepter_region

  depends_on = [aws_vpc_peering_connection_accepter.this]
}

resource "aws_route53_zone_association" "requester" {
  count    = var.requester.private_domain != null ? 1 : 0
  provider = aws.accepter

  zone_id    = data.aws_route53_zone.requester[0].zone_id
  vpc_id     = var.accepter.vpc_id
  vpc_region = local.accepter_region

  depends_on = [aws_route53_vpc_association_authorization.requester]
}
