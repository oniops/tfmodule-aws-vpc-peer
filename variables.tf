variable "name" {
  description = "Key of this peering connection. Becomes the <key> part of the Name tag <name_prefix>-<key>-pcx, so it must be unique among the peering connections of the requester VPC. This module does not check that uniqueness; reusing a value makes the Name tags collide and the connections indistinguishable in the console. Lowercase letters, digits and hyphens only. Stays required even when fullname is set: it keeps identifying this peering connection in the caller's configuration."
  type        = string

  validation {
    condition     = can(regex("^[a-z0-9][a-z0-9-]*$", var.name))
    error_message = "name must start with a lowercase letter or digit and contain only lowercase letters, digits and hyphens."
  }
}

variable "fullname" {
  description = <<-EOF
Optional override of the Name tag. When set, the Name tag of the peering connection is this value verbatim; when omitted (null, the default), the Name tag stays <name_prefix>-<name>-pcx.

Use it to spell out the requester -> accepter direction of the connection, which the default rule cannot express because it only knows the requester side prefix. The module appends nothing, so add the -pcx suffix yourself if you want it. The value replaces only the Name tag: it does not change the resource addresses or the for_each keys of any resource, so switching to it never recreates anything (the Name tag is updated in place).

Character rule: lowercase letters, digits, hyphens and spaces. It must start with a lowercase letter or digit and must not end with a space. Unlike name, spaces are allowed because the value is used only as a tag value.

  fullname = "finops com-an2p-vpc to dev-an2d-vpc"
EOF
  type        = string
  default     = null

  validation {
    condition     = var.fullname == null || can(regex("^[a-z0-9]([a-z0-9 -]*[a-z0-9-])?$", var.fullname))
    error_message = "fullname must start with a lowercase letter or digit, contain only lowercase letters, digits, hyphens and spaces, and not end with a space when set."
  }
}

variable "requester" {
  description = <<-EOF
Requester side of the peering connection. The requester VPC lives in the account and region of the default `aws` provider.

  - vpc_id                          : requester VPC ID
  - allow_remote_vpc_dns_resolution : resolve public DNS hostnames of the accepter VPC to private IP addresses. Default true
  - private_domain                  : name of a Route53 private hosted zone owned by the requester account. When set, the zone is
                                      associated with the accepter VPC so that the accepter VPC can resolve its records. The zone is
                                      looked up by name in the requester VPC, so a zone with that exact name must already be
                                      associated with requester.vpc_id or plan fails
  - routes                          : routes toward the accepter VPC, keyed by a name of your choice (route table key is recommended).
                                      Identify the requester route table with exactly one of route_table_id or route_table_name
                                      (Name tag, looked up in the requester VPC; plan fails when no route table or more than one
                                      matches). destination_cidr_block is an accepter VPC CIDR; opening it lets the requester VPC
                                      reach the whole accepter CIDR range and actual access control stays with the accepter VPC
                                      security groups and NACLs. If the requester route table already has a route for the same
                                      destination CIDR, AWS rejects the creation during apply. Traffic over these routes may incur
                                      cross-region or cross-AZ data transfer cost that does not appear in the plan.

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
Accepter side of the peering connection. The accepter VPC lives in the account and region of the `aws.accepter` provider.

  - account_id                      : AWS account ID that owns the accepter VPC. When omitted (null), it is derived from
                                      the aws.accepter provider via sts:GetCallerIdentity. When set explicitly, it must
                                      match the account actually assumed by aws.accepter, or plan fails
  - region                          : region of the accepter VPC. When omitted (null), it is derived from the
                                      aws.accepter provider's configured region. When set explicitly, it must match
                                      the aws.accepter provider's region, or plan fails
  - vpc_id                          : accepter VPC ID
  - allow_remote_vpc_dns_resolution : resolve public DNS hostnames of the requester VPC to private IP addresses. Default true
  - private_domain                  : name of a Route53 private hosted zone owned by the accepter account. When set, the zone is
                                      associated with the requester VPC so that the requester VPC can resolve its records. The zone
                                      is looked up by name in the accepter VPC, so a zone with that exact name must already be
                                      associated with accepter.vpc_id or plan fails
  - routes                          : routes toward the requester VPC, keyed by a name of your choice (route table key is
                                      recommended). Identify the accepter route table with exactly one of route_table_id or
                                      route_table_name (Name tag, looked up in the accepter VPC; plan fails when no route table or
                                      more than one matches). destination_cidr_block is a requester VPC CIDR; opening it lets the
                                      accepter VPC reach the whole requester CIDR range and actual access control stays with the
                                      requester VPC security groups and NACLs. If the accepter route table already has a route for
                                      the same destination CIDR, AWS rejects the creation during apply. Traffic over these routes
                                      may incur cross-region or cross-AZ data transfer cost that does not appear in the plan.

  accepter = {
    vpc_id         = "vpc-0123456789abcdef0"
    private_domain = "ew1p.sample.internal"
    routes = {
      pub = { route_table_id   = "rtb-0123456789abcdef0", destination_cidr_block = "10.205.0.0/16" }
      pri = { route_table_name = "sample-ew1p-pri-rt", destination_cidr_block = "10.205.0.0/16" }
    }
  }
EOF
  type = object({
    account_id                      = optional(string)
    region                          = optional(string)
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
    condition     = var.accepter.account_id == null || can(regex("^[0-9]{12}$", var.accepter.account_id))
    error_message = "accepter.account_id must be a 12-digit AWS account ID when set."
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
  description = "Additional tags applied to every taggable resource of both sides after context.tags. The Name key is protected: it is merged last by the module and cannot be overridden."
  type        = map(string)
  default     = {}

  validation {
    condition     = !contains(keys(var.tags), "Name")
    error_message = "tags must not contain the protected key Name."
  }
}
