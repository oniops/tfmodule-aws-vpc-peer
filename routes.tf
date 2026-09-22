#####################################################################
# Routes
#
# A route table is identified by route_table_id, or by route_table_name
# which is looked up as the Name tag of a route table in the same VPC.
#####################################################################

data "aws_route_table" "requester" {
  for_each = { for key, route in var.requester.routes : key => route if route.route_table_name != null }

  vpc_id = var.requester.vpc_id

  filter {
    name   = "tag:Name"
    values = [each.value.route_table_name]
  }
}

data "aws_route_table" "accepter" {
  provider = aws.accepter
  for_each = { for key, route in var.accepter.routes : key => route if route.route_table_name != null }

  vpc_id = var.accepter.vpc_id

  filter {
    name   = "tag:Name"
    values = [each.value.route_table_name]
  }
}

# Requester route tables -> accepter VPC CIDR
resource "aws_route" "requester" {
  for_each = var.requester.routes

  route_table_id            = each.value.route_table_id != null ? each.value.route_table_id : data.aws_route_table.requester[each.key].id
  destination_cidr_block    = each.value.destination_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  timeouts {
    create = "5m"
    update = "5m"
    delete = "5m"
  }
}

# Accepter route tables -> requester VPC CIDR
resource "aws_route" "accepter" {
  provider = aws.accepter
  for_each = var.accepter.routes

  route_table_id            = each.value.route_table_id != null ? each.value.route_table_id : data.aws_route_table.accepter[each.key].id
  destination_cidr_block    = each.value.destination_cidr_block
  vpc_peering_connection_id = aws_vpc_peering_connection_accepter.this.id

  timeouts {
    create = "5m"
    update = "5m"
    delete = "5m"
  }
}
