output "id" {
  description = "VPC peering connection ID."
  value       = aws_vpc_peering_connection.this.id
}

output "name" {
  description = "Name tag of the peering connection, <name_prefix>-<name>-pcx."
  value       = local.name
}

output "accept_status" {
  description = "Status of the peering connection after acceptance."
  value       = aws_vpc_peering_connection_accepter.this.accept_status
}

output "requester_route_ids" {
  description = "Route IDs created in the requester route tables, keyed by requester.routes key."
  value       = { for key, route in aws_route.requester : key => route.id }
}

output "accepter_route_ids" {
  description = "Route IDs created in the accepter route tables, keyed by accepter.routes key."
  value       = { for key, route in aws_route.accepter : key => route.id }
}

output "requester_private_zone_id" {
  description = "Hosted zone ID of requester.private_domain associated with the accepter VPC. null when not configured."
  value       = one(data.aws_route53_zone.requester[*].zone_id)
}

output "accepter_private_zone_id" {
  description = "Hosted zone ID of accepter.private_domain associated with the requester VPC. null when not configured."
  value       = one(data.aws_route53_zone.accepter[*].zone_id)
}
