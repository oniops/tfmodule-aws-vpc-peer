variable "context" {
  description = <<-EOF
Output object of the tfmodule-context module (v1.3.5). Only the fields this module uses are required; every other field is optional and ignored.

  - name_prefix : prefix of the Name tag. The peering connection is named <name_prefix>-<name>-pcx
  - tags        : organization common tags. First stage of the tag merge for every resource
  - region      : region of the requester VPC. Used for the Route53 private hosted zone association authorization

  context = module.ctx.context
EOF
  type = object({
    name_prefix  = string
    tags         = map(string)
    region       = string
    region_alias = optional(string)
    project      = optional(string)
    environment  = optional(string)
    env_alias    = optional(string)
    owner        = optional(string)
    team         = optional(string)
    cost_center  = optional(number)
    pri_domain   = optional(string)
  })
}
