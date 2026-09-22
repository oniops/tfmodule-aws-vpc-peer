variable "name" {
  description = "Key of this peering connection. Becomes the <key> part of the Name tag <name_prefix>-<key>-pcx, so it must be unique among the peering connections of the requester VPC. Lowercase letters, digits and hyphens only."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.name))
    error_message = "name must start with a lowercase letter or digit and contain only lowercase letters, digits and hyphens."
  }
}

variable "requester" {
  description = <<-EOF
Requester side of the peering connection. The requester VPC lives in the account and region of the default `aws` provider.

  - vpc_id                          : requester VPC ID
  - allow_remote_vpc_dns_resolution : resolve public DNS hostnames of the accepter VPC to private IP addresses. Default true
  - private_domain                  : name of a Route53 private hosted zone owned by the requester account. When set, the zone is
                                      associated with the accepter VPC so that the accepter VPC can resolve its records
  - routes                          : routes toward the accepter VPC, keyed by a name of your choice (route table key is recommended).
                                      Identify the requester route table with exactly one of route_table_id or route_table_name
                                      (Name tag, looked up in the requester VPC). destination_cidr_block is an accepter VPC CIDR

  requester = {
    vpc_id         = module.vpc.vpc_id
    private_domain = "an2p.sample.internal"
    routes = {
      pri-a1 = { route_table_id   = module.vpc.route_table_ids["pri-a1"], destination_cidr_block = "10.230.0.0/16" }
      pri-c1 = { route_table_name = "sample-an2p-pri-c1-rt", destination_cidr_block = "10.230.0.0/16" }
    }
  }
EOF
  type = object({
    vpc_id                          = string
    allow_remote_vpc_dns_resolution = optional(bool, true)
    private_domain                  = optional(string)
    routes = optional(map(object({
      route_table_id         = optional(string)
      route_table_name       = optional(string)
      destination_cidr_block = string
    })), {})
  })

  validation {
    condition     = alltrue([for route in values(var.requester.routes) : (route.route_table_id != null) != (route.route_table_name != null)])
    error_message = "requester.routes[*] must set exactly one of route_table_id or route_table_name."
  }

  validation {
    condition     = alltrue([for route in values(var.requester.routes) : can(cidrhost(route.destination_cidr_block, 0))])
    error_message = "requester.routes[*].destination_cidr_block must be a valid IPv4 CIDR block."
  }
}

variable "accepter" {
  description = <<-EOF
Accepter side of the peering connection. The accepter VPC lives in the account and region of the `aws.accepter` provider,
and account_id and region must match that provider.

  - account_id                      : AWS account ID that owns the accepter VPC
  - region                          : region of the accepter VPC
  - vpc_id                          : accepter VPC ID
  - allow_remote_vpc_dns_resolution : resolve public DNS hostnames of the requester VPC to private IP addresses. Default true
  - private_domain                  : name of a Route53 private hosted zone owned by the accepter account. When set, the zone is
                                      associated with the requester VPC so that the requester VPC can resolve its records
  - routes                          : routes toward the requester VPC, keyed by a name of your choice (route table key is recommended).
                                      Identify the accepter route table with exactly one of route_table_id or route_table_name
                                      (Name tag, looked up in the accepter VPC). destination_cidr_block is a requester VPC CIDR

  accepter = {
    account_id     = "111122223333"
    region         = "eu-west-1"
    vpc_id         = "vpc-0123456789abcdef0"
    private_domain = "ew1p.sample.internal"
    routes = {
      pub = { route_table_id   = "rtb-0123456789abcdef0", destination_cidr_block = "10.205.0.0/16" }
      pri = { route_table_name = "sample-ew1p-pri-rt", destination_cidr_block = "10.205.0.0/16" }
    }
  }
EOF
  type = object({
    account_id                      = string
    region                          = string
    vpc_id                          = string
    allow_remote_vpc_dns_resolution = optional(bool, true)
    private_domain                  = optional(string)
    routes = optional(map(object({
      route_table_id         = optional(string)
      route_table_name       = optional(string)
      destination_cidr_block = string
    })), {})
  })

  validation {
    condition     = can(regex("^[0-9]{12}$", var.accepter.account_id))
    error_message = "accepter.account_id must be a 12-digit AWS account ID."
  }

  validation {
    condition     = alltrue([for route in values(var.accepter.routes) : (route.route_table_id != null) != (route.route_table_name != null)])
    error_message = "accepter.routes[*] must set exactly one of route_table_id or route_table_name."
  }

  validation {
    condition     = alltrue([for route in values(var.accepter.routes) : can(cidrhost(route.destination_cidr_block, 0))])
    error_message = "accepter.routes[*].destination_cidr_block must be a valid IPv4 CIDR block."
  }
}

variable "tags" {
  description = "Additional tags applied to every resource of both sides after context.tags. The Name key is protected and cannot be overridden."
  type        = map(string)
  default     = {}

  validation {
    condition     = !contains(keys(var.tags), "Name")
    error_message = "tags must not contain the protected key Name."
  }
}
