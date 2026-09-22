variable "context" {
  description = <<-EOF
Output object of the tfmodule-context module (v1.3.6 or later). Only the fields this module uses are required; every other field is optional and ignored.

  - name_prefix : prefix of the Name tag. The peering connection is named <name_prefix>-<name>-pcx.
                  A long name_prefix makes the Name tag long; this module does not check the tag length
  - tags        : organization common tags. First stage of the tag merge for every resource
  - region      : region of the requester VPC. Used as the vpc_region argument of the Route53 private hosted
                  zone association authorization

  context = module.ctx.context
EOF
  type = object({
    name_prefix  = string
    tags         = map(string)
    region       = string
    project      = optional(string)
    environment  = optional(string)
    owner        = optional(string)
    team         = optional(string)
    cost_center  = optional(string)
    pri_domain   = optional(string)
  })

  validation {
    condition     = var.context.name_prefix != null
    error_message = "context.name_prefix must not be null. Check that the referenced tfmodule-context module version is v1.3.6 or later and that context is passed as module.ctx.context."
  }

  validation {
    condition     = var.context.tags != null
    error_message = "context.tags must not be null."
  }

  validation {
    condition     = var.context.region != null
    error_message = "context.region must not be null. It is used as the vpc_region argument of the Route53 private hosted zone association authorization."
  }
}
