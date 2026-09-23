# tfmodule-aws-vpc-peer 요구사항 및 계약

이 문서는 `tfmodule-aws-vpc-peer` 모듈이 **무엇을 충족해야 하는가**를 다룬다. 기능 요구사항, 입력·출력 계약, 변수 구조 진단과 개선안(HCL), 개선 전/후 비교와 SemVer 판정, tfmodule-context 의존성 정책(v1.3.6 이상 필수), 검증 배치표, 테스트 요구사항, Terraform/Provider 버전 정책, Definition of Done 체크리스트를 확정한다.

- **"왜 이렇게 설계했는가"**(아키텍처 개요, 모듈 경계, Hub & Spoke 패턴, kylo pcx 대조 분석, 네이밍·태그·보안 설계 근거, DECISIONS)는 [ARCHITECTURE.md](ARCHITECTURE.md) 를 참조한다.
- **"어떻게 쓰는가"**는 [README.md](../README.md) 를 참조한다.

이 문서가 확정하는 계약과 정책은 시니어 모듈 정책 스페셜리스트의 판정 기준이며, 실제 코드 반영(`main.tf`, `variables.tf`, `variables-context.tf`, `outputs.tf`, `routes.tf`, `route53-zone.tf` 수정, README 표 갱신, `examples/`/`tests/` 작성·실행, 보안·비용 스캔, 릴리스 태그)은 `terraform-aws-module-engineer` 에게 위임한다.

---

## 1. 기능 요구사항

1. 서로 다른 계정·리전에 있는 두 VPC 사이에 Peering 을 요청하고 자동 수락한다.
2. 요청/수락 양쪽에 독립적으로 DNS 해석 옵션(`allow_remote_vpc_dns_resolution`)을 설정한다.
3. 요청/수락 양쪽에 여러 개의 Route Table 경로를 추가할 수 있다. 경로는 `route_table_id` 또는 `route_table_name`(같은 VPC 안의 `Name` 태그 조회) 중 하나로 지정한다.
4. 요청/수락 양쪽에서 독립적으로, 자신이 소유한 Route53 Private Hosted Zone 을 상대 VPC 에 연결(Authorization + Association)할 수 있다.
5. 같은 계정·리전 안의 두 VPC 도 연결할 수 있다(양쪽에 같은 provider 를 넘기는 것으로 표현).
6. 항목(`routes` 의 키, `private_domain` on/off)을 추가·제거해도 다른 항목에 변경(`~`)·재생성(`-/+`)이 발생하지 않는다.
7. 잘못된 입력 조합(Route Table 이중 지정, CIDR 형식 오류, 계정 ID 형식 오류, `Name` 태그 충돌, 존재하지 않는 참조 등)은 `plan` 단계에서 실패한다.
8. `Name` 태그는 기본적으로 `<name_prefix>-<name>-pcx` 로 파생하되, 요청 VPC → 수락 VPC 의 연결 흐름을 이름으로 표현할 수 있도록 선택 입력 `fullname` 으로 이름 전체를 대체할 수 있다. `fullname` 을 생략하면 기존 규칙과 완전히 같은 이름이 나온다(하위 호환).

---

## 2. 입력·출력 계약 (현행)

§4 의 개선안이 반영된 뒤의 현행 계약이다. 개선 전 기준선과의 차이는 §5.1 에서 비교한다.

### 2.1 입력 변수

| 이름 | 타입 | 기본값 | 필수 |
| --- | --- | --- | --- |
| `context` | `object({ name_prefix, tags, region, region_alias?, project?, environment?, env_alias?, owner?, team?, cost_center?, pri_domain? })` | 없음 | 예 |
| `name` | `string` | 없음 | 예 |
| `fullname` | `string` | `null` | 아니오 |
| `requester` | `object({ vpc_id, allow_remote_vpc_dns_resolution?, private_domain?, routes? })` | 없음 | 예 |
| `accepter` | `object({ account_id?, region?, vpc_id, allow_remote_vpc_dns_resolution?, private_domain?, routes? })` | 없음 | 예 |
| `tags` | `map(string)` | `{}` | 아니오 |

### 2.2 출력 (9개)

| 이름 | 설명 |
| --- | --- |
| `id` | VPC Peering 연결 ID |
| `name` | Peering 연결의 `Name` 태그 값. `fullname` 지정 시 그 값, 미지정 시 `<name_prefix>-<name>-pcx` |
| `accept_status` | 수락 후 연결 상태 |
| `requester_route_ids` | `requester.routes` 키 → 요청 측에 생성한 경로 ID |
| `accepter_route_ids` | `accepter.routes` 키 → 수락 측에 생성한 경로 ID |
| `requester_private_zone_id` | 수락 VPC 에 연결한 요청 측 Hosted Zone ID. `requester.private_domain` 미설정이면 `null` |
| `accepter_private_zone_id` | 요청 VPC 에 연결한 수락 측 Hosted Zone ID. `accepter.private_domain` 미설정이면 `null` |
| `accepter_account_id` | 실제로 사용된 수락 계정 ID(명시값 또는 `aws.accepter` provider 파생값) |
| `accepter_region` | 실제로 사용된 수락 리전(명시값 또는 `aws.accepter` provider 파생값) |

이 계약은 Published Module 의 Public API 다. 제거·이름 변경·타입 변경은 Breaking Change(MAJOR)로 분류한다(§5).

---

## 3. 변수 구조 진단

요청 기준(이해 용이성 / 확장 용이성 / 입력 중복 여부 / 불필요한 설정 강요 여부)으로 현재 계약을 항목별로 진단한다.

### 3.1 이해·확장 용이성 — 양호(변경 불필요)

- `requester`/`accepter` 를 대칭 구조(같은 필드 셋)로 둔 것은 사용자가 한쪽을 이해하면 다른 쪽도 바로 이해할 수 있게 한다.
- `routes` 를 `list` 가 아닌 `map(object({...}))` 로 키를 호출자가 정하게 한 것은 "복수 입력은 이름 키의 map" 원칙과 정확히 일치하며, 항목 추가·제거 시 다른 항목에 영향이 없는 멱등 구조를 이미 달성했다.
- `route_table_id`/`route_table_name` 중 정확히 하나만 요구하는 상호 배타 필드 쌍은 사용자가 "ID 를 알면 ID 로, 모르면 이름으로" 직관적으로 선택할 수 있게 한다.

### 3.2 입력 중복 — 위반 발견

`accepter.account_id`, `accepter.region` 은 사실상 **호출자가 이미 다른 곳(provider 블록)에 적은 값을 다시 한번 적어야 하는 구조**다.

```hcl
# 호출자가 실제로 작성해야 하는 코드
provider "aws" {
  alias  = "accepter"
  region = "eu-west-1"                                          # <- 리전 1
  assume_role {
    role_arn = "arn:aws:iam::111122223333:role/PeeringAccepter" # <- 계정 ID 1
  }
}

module "vpc_peer" {
  providers = { aws = aws, aws.accepter = aws.accepter }
  accepter = {
    account_id = "111122223333"  # <- 계정 ID 2 (provider 의 role_arn 과 동일한 값)
    region     = "eu-west-1"     # <- 리전 2 (provider 의 region 과 동일한 값)
    vpc_id     = "vpc-0123456789abcdef0"
  }
}
```

계정 ID·리전은 이미 `aws.accepter` provider 자체가 "어느 계정, 어느 리전에 접속할지"로 결정하는 값이다. 호출자가 같은 정보를 변수로 다시 입력해야 하며, 두 값이 어긋나면(오탈자, 복붙 실수) AWS 가 Peering 요청을 거부하거나 엉뚱한 계정으로 인가(Authorization)를 시도하는 등 원인 파악이 어려운 오류로 이어진다. kylo pcx 에서도 동일한 패턴(계정 ID가 `role_arn`과 `stages` 맵 양쪽에 하드코딩)이 있었고, 13개 파일에 걸쳐 계정 ID를 두 번씩 관리해야 했던 것이 유지보수 비용의 큰 축이었다(ARCHITECTURE.md §3).

**판정: 정책 위반. 개선 필요(→ §4.2, DECISION D-002).**

### 3.3 불필요한 설정 강요 — 위반 발견 (3.2 와 동일 원인)

`account_id`, `region` 은 Terraform 이 `aws.accepter` provider 로부터 **직접 조회할 수 있는 값**이다(`data "aws_caller_identity"`, `data "aws_region"`). 즉 "합리적 기본값(provider 로부터 파생)으로 대체 가능한 입력"임에도 현재는 필수 입력으로 강요하고 있다.

**판정: Convention over Configuration 원칙 위반. 개선 필요.**

### 3.4 `context` 필드의 `null` 방어 — 위반 발견

`variables-context.tf` 는 `name_prefix`, `tags`, `region` 을 필수(비-`optional`) 필드로 선언하지만, Terraform 객체 타입에서 필수 필드는 "키가 반드시 존재"함을 보장할 뿐 "값이 `null` 이 아님"을 보장하지 않는다. 현재 코드는 이 값들을 방어 없이 바로 사용한다.

```hcl
# main.tf:2 — name_prefix 가 null 이면 문자열 보간이 조용히 "-<name>-pcx" 로 축약된다(에러 없음)
local.name = "${var.context.name_prefix}-${var.name}-pcx"

# route53-zone.tf:24 — region 이 null 이면 vpc_region = null 로 apply 단계에서 AWS 제공자 오류 발생
vpc_region = var.context.region
```

이는 "필수 필드라도 값이 `null` 일 수 있다. 그 값을 실제로 쓰는 시점에 `null` 이면 plan 단계에서 실패시킨다"를 위반한다.

**판정: 정책 위반. `validation` 추가 필요(단일 변수 `context` 내부 필드 검사이므로 `validation` 으로 분류. Terraform 1.5.7 에서도 가능. → DECISION D-006).**

### 3.5 구조적 중복(허용) — 변경 불필요

`routes` 의 항목 타입(`{ route_table_id, route_table_name, destination_cidr_block }`)이 `requester`, `accepter` 두 변수에 각각 인라인으로 반복된다. 이는 HCL 이 변수 간 타입을 공유(타입 별칭)하는 문법을 제공하지 않기 때문에 생기는 **언어 차원의 불가피한 중복**이며, 사용자 입력 관점에서는 중복이 아니다(같은 정보를 두 번 입력하게 만들지 않는다). **개선 대상에서 제외.**

---

## 4. 개선안 (HCL)

### 4.1 `variables-context.tf` — `null` 방어 추가

```hcl
variable "context" {
  description = <<-EOF
tfmodule-context(v1.3.6 이상) 출력 객체. 이 모듈이 쓰는 필드만 필수로 받고 나머지는 optional 로 받아 무시한다.

  - name_prefix : Name 태그 접두어. <name_prefix>-<name>-pcx
  - tags        : 조직 공통 태그. 태그 병합 1단계
  - region      : 요청 VPC 리전. Route53 Private Hosted Zone 교차 연결 인가(vpc_region)에 사용

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
```

- 세 필드 모두 **자기 변수(`context`) 안에서 끝나는 검사**이므로 `validation` 으로 분류한다. Terraform 1.9 상향 없이 현행 `required_version >= 1.5.7` 로 충분하다.
- 이 변경은 정상적인 `context`(모든 실사용 tfmodule-context 출력)에는 아무 영향이 없다. `null` 을 의도적으로 넣는 비정상 입력만 더 이른 시점(plan)에서 더 명확한 메시지로 막는다.
- **SemVer 분류: PATCH**(버그 수정 — 기존에도 실패해야 했던 입력이 이제야 명확히 실패한다. 정상 입력의 동작·출력은 불변). → DECISION D-006

### 4.2 `variables.tf` — `accepter.account_id`/`region` 을 선택 입력 + 파생 기본값으로 전환

```hcl
variable "accepter" {
  description = <<-EOF
Accepter side of the peering connection. The accepter VPC lives in the account and region of the `aws.accepter` provider.

  - account_id                      : AWS account ID that owns the accepter VPC. When omitted (null), it is derived from
                                      the aws.accepter provider via sts:GetCallerIdentity. When set explicitly, it must
                                      match the account actually assumed by aws.accepter, or plan fails.
  - region                          : region of the accepter VPC. When omitted (null), it is derived from the
                                      aws.accepter provider's configured region. When set explicitly, it must match
                                      the aws.accepter provider's region, or plan fails.
  - vpc_id                          : accepter VPC ID
  - allow_remote_vpc_dns_resolution : resolve public DNS hostnames of the requester VPC to private IP addresses. Default true
  - private_domain                  : name of a Route53 private hosted zone owned by the accepter account. When set, the zone is
                                      associated with the requester VPC so that the requester VPC can resolve its records
  - routes                          : routes toward the requester VPC, keyed by a name of your choice (route table key is
                                      recommended). Identify the accepter route table with exactly one of route_table_id or
                                      route_table_name (Name tag, looked up in the accepter VPC). destination_cidr_block is a
                                      requester VPC CIDR. Traffic over these routes may incur cross-region data transfer cost
                                      that does not appear in the plan.

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
```

`account_id`, `region` 에 대한 정규식/필수 검사는 `null` 허용을 반영해 `var.accepter.account_id == null || ...` 형태로 완화한다(자기 변수 내부 검사이므로 여전히 `validation`). → DECISION D-002

### 4.3 `main.tf` — 파생 값 조회와 일치성 검증(`postcondition`)

```hcl
#####################################################################
# Accepter identity/region derivation
#
# account_id/region은 aws.accepter provider가 이미 알고 있는 값이므로
# 입력이 없으면(null) provider로부터 조회하고, 입력이 있으면 provider의
# 실제 값과 일치하는지 검증한다. 호출자가 provider 블록과 변수 양쪽에
# 같은 값을 중복 관리하지 않아도 되게 한다.
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
      # data.aws_region.region, so the current attribute is used.
      condition     = var.accepter.region == null || var.accepter.region == self.region
      error_message = "accepter.region (${coalesce(var.accepter.region, "null")}) does not match the region of the aws.accepter provider (${self.region})."
    }
  }
}

locals {
  accepter_account_id = coalesce(var.accepter.account_id, data.aws_caller_identity.accepter.account_id)
  accepter_region     = coalesce(var.accepter.region, data.aws_region.accepter.region)
}

resource "aws_vpc_peering_connection" "this" {
  vpc_id        = var.requester.vpc_id
  peer_vpc_id   = var.accepter.vpc_id
  peer_owner_id = local.accepter_account_id
  peer_region   = local.accepter_region

  tags = local.tags
}
```

`routes.tf`, `route53-zone.tf` 의 `var.accepter.region` 참조는 모두 `local.accepter_region` 으로 바꾼다(engineer 위임 사항).

**배치 근거(참조 방향):** 이 검사는 "입력 변수 하나"와 "provider 가 실제로 응답한 값"을 비교하는 **두 변수 이상을 함께 보는 검사**이므로 `precondition`/`postcondition` 대상이다. 값 비교의 대상(`self.account_id`, `self.region`)이 데이터 소스 조회 **이후**에만 존재하므로 `precondition` 이 아니라 **`postcondition`** 이며, 참조 관계상 이 값을 만들어내는 데이터 소스 자신에 배치하는 것이 "나중에 오는 리소스에 둔다" 원칙에 부합한다. → DECISION D-003

### 4.4 `outputs.tf` — 파생 값 노출 추가

```hcl
output "accepter_account_id" {
  description = "Resolved accepter AWS account ID (explicit accepter.account_id, or derived from the aws.accepter provider when omitted)."
  value       = local.accepter_account_id
}

output "accepter_region" {
  description = "Resolved accepter region (explicit accepter.region, or derived from the aws.accepter provider when omitted)."
  value       = local.accepter_region
}
```

`account_id`/`region` 을 생략한 호출자가 실제로 어떤 값이 사용됐는지 확인할 수 있게 한다.

### 4.5 태그 병합 순서 교정

```hcl
# 개선 후 (ARCHITECTURE.md §5.1, DECISION D-004)
locals {
  tags = merge(var.context.tags, var.tags, { Name = local.name })
}
```

유효한 입력(즉 `tags` 에 `Name` 을 넣지 않는 모든 기존 호출자)에게는 동작 변화가 없다. `aws_vpc_peering_connection_accepter.this` 를 포함해 태그를 지원하는 모든 리소스가 `local.tags` 를 그대로 참조하도록 유지한다(현재도 그러함).

### 4.6 `variables.tf`/`main.tf` — `Name` 태그 전체를 대체하는 선택 입력 `fullname`

기본 산식 `<name_prefix>-<name>-pcx` 의 접두어는 요청(requester) 측 `context` 에서만 오므로 "어느 VPC → 어느 VPC" 라는 연결 흐름을 이름으로 표현할 수 없다. 수락 측 접두어에 해당하는 정보는 모듈 입력(`vpc_id` + provider)만으로 파생할 수 없으므로, 조합 규칙을 늘리는 대신 **이름 전체를 호출자가 지정하는 탈출구 입력 하나**를 둔다(ARCHITECTURE.md §4, DECISION D-009).

```hcl
variable "fullname" {
  description = <<-EOF
Optional override of the Name tag. When set, the Name tag of the peering connection is this value verbatim; when omitted (null, the default), the Name tag stays <name_prefix>-<name>-pcx.

Use it to spell out the requester -> accepter direction of the connection, which the default rule cannot express because it only knows the requester side prefix. The module appends nothing, so add the -pcx suffix yourself if you want it. The value replaces only the Name tag: it does not change the resource addresses or the for_each keys of any resource, so switching to it never recreates anything (the Name tag is updated in place).

Character rule: lowercase letters, digits, hyphens and spaces. It must start with a lowercase letter or digit and must not end with a space. Unlike name, spaces are allowed because the value is used only as a tag value.

  fullname = "fsec-an2p-to-dev-an2d-pcx"
EOF
  type        = string
  default     = null

  validation {
    condition     = var.fullname == null || can(regex("^[a-z0-9]([a-z0-9 -]*[a-z0-9-])?$", var.fullname))
    error_message = "fullname must start with a lowercase letter or digit, contain only lowercase letters, digits, hyphens and spaces, and not end with a space when set."
  }
}
```

```hcl
locals {
  name = var.fullname != null ? var.fullname : "${var.context.name_prefix}-${var.name}-pcx"
  tags = merge(var.context.tags, var.tags, { Name = local.name })
}
```

확정 사항:

| 항목 | 결정 | 근거 |
| --- | --- | --- |
| `fullname` 의 필수 여부 | `optional`(`default = null`). 미지정 시 기존 산식 그대로 | 하위 호환. 기존 호출자의 `Name` 태그가 한 글자도 바뀌지 않아야 한다 |
| `name` 의 필수 여부 | **필수 유지** | `name` 은 호출자 구성 안에서 이 연결을 식별하는 키이며, 선택으로 완화하면 `fullname`·`name` 이 모두 없는 경우를 막기 위한 "두 변수를 함께 보는 검사"가 필요해진다. 그 검사는 `required_version >= 1.5.7` 에서 변수 `validation` 으로 표현할 수 없어 리소스 `precondition` 으로 내려가야 하고(§9), 검사 배치표에 행이 하나 더 늘며 `name_prefix--pcx` 같은 축약 이름이 조용히 만들어질 위험만 남는다. 완화로 얻는 이득이 없다 |
| `fullname` 의 `validation` | `null` 허용 + `name` 과 동일한 정규식(§7 표 16) | 이름 문자 규칙이 입력에 따라 달라지면 조직 네이밍 표준이 두 갈래가 된다. 빈 문자열(`""`)도 이 정규식에서 걸러진다 |
| 접미어 자동 부착 | 하지 않는다 | "값 그대로"가 이 입력의 계약이다. `-pcx` 가 필요하면 호출자가 값에 포함한다 |
| 리소스 주소 영향 | 없음 | `local.name` 은 `Name` 태그와 출력 `name` 에서만 쓰이며 어떤 `for_each` 키·리소스 주소에도 쓰이지 않는다(코드 전수 확인). 따라서 기존 상태에 `fullname` 을 새로 지정해도 태그 in-place 갱신(`~`)만 발생하고 재생성(`-/+`)은 0건이다 |

---

## 5. 개선 전/후 비교와 마이그레이션 영향

### 5.1 개선 전/후 비교

| 항목 | 개선 전 | 개선 후 |
| --- | --- | --- |
| `accepter.account_id` | `string`(필수) | `optional(string)`(생략 시 provider 에서 파생) |
| `accepter.region` | `string`(필수) | `optional(string)`(생략 시 provider 에서 파생) |
| 입력 중복 | provider 블록 + 변수 양쪽에 계정 ID·리전 기재 | provider 블록 하나로 충분(변수는 선택적 재확인용 override) |
| 오탈자 방어 | 없음(값이 어긋나도 AWS 오류로만 드러남) | `postcondition` 으로 plan/apply 초입에 명확한 오류 |
| `context.name_prefix`/`tags`/`region` 이 `null` 인 경우 | 조용히 빈 문자열 보간 또는 apply 단계 AWS 오류 | `validation` 으로 plan 단계에서 명확히 실패 |
| 태그 병합 순서 | `merge(context.tags, {Name}, tags)` | `merge(context.tags, tags, {Name})` |
| 출력 개수 | 7개 | 9개(`accepter_account_id`, `accepter_region` 추가) |
| `Name` 태그 산식 | `<name_prefix>-<name>-pcx` 고정 | 기본은 동일. 선택 입력 `fullname` 을 적으면 그 값 그대로(연결 흐름을 이름에 담을 수 있음) |

### 5.2 마이그레이션 영향과 SemVer 분류

| 변경 | 기존 호출자(정상 입력) 영향 | Breaking 여부 | SemVer |
| --- | --- | --- | --- |
| `accepter.account_id`/`region` required → optional | 없음. 기존처럼 명시적으로 값을 적어 호출하는 코드는 그대로 동작하며, 추가로 provider 실제 값과의 일치 검증이 더해진다 | 아니오(필수→선택 완화는 항상 하위 호환) | MINOR |
| `postcondition` 추가(계정 ID/리전 불일치 검증) | 기존에 **이미 값이 일치하던** 호출자는 영향 없음. 기존에 값이 어긋나 있었지만 우연히 동작하던(혹은 잘못된 계정으로 조용히 Peering 이 만들어지던) 드문 케이스는 새로 plan 이 실패할 수 있음 | 기능 제거가 아닌 결함 차단이므로 Breaking Change 로 분류하지 않되, 릴리스 노트에 동작 강화(hardening)로 명시 | MINOR 에 포함 |
| `context.*` null 검증 추가 | `context` 를 tfmodule-context 출력 그대로 넘기는 모든 정상 호출자는 영향 없음 | 아니오 | PATCH(단독 릴리스 시) / MINOR 릴리스에 포함 가능 |
| 태그 병합 순서 변경 | 없음(`tags` 에 `Name` 입력은 이미 금지되어 있어 결과값 불변) | 아니오 | PATCH |
| 출력 2개 추가 | 없음(추가만 발생, 기존 출력 유지) | 아니오 | MINOR |
| 선택 입력 `fullname` 추가 | 없음. 미지정이 기본이고 그때 `Name` 태그는 기존과 완전히 동일하다. 지정한 호출자만 `Name` 태그가 in-place 로 갱신된다(재생성 0건) | 아니오(선택 입력 추가) | MINOR |
| 리소스 키 산식 | 변경 없음(`aws_route.requester`/`accepter` 의 `for_each` 키는 `var.*.routes` 키 그대로 유지) | 아니오 | — |
| 리소스 주소(타입/로컬 이름) | `aws_vpc_peering_connection.this` 등 기존 리소스 주소 불변. `fullname` 은 `Name` 태그와 출력 `name` 에서만 쓰이고 리소스 주소·`for_each` 키 산식에 관여하지 않는다. `data.aws_caller_identity.accepter`, `data.aws_region.accepter` 는 신규 **데이터 소스**이므로 기존 상태 리소스의 재생성을 유발하지 않음(데이터 소스는 관리 상태를 갖지 않는다) | 아니오 | — |

**종합 판정: 이번 개선안 전체를 하나의 릴리스로 묶을 경우 MINOR 로 분류한다.** MAJOR 로 올려야 하는 항목(입력 제거, 출력 제거/타입 변경, 리소스 키 산식 변경, 기본 동작의 중대한 변경)은 이번 개선안에 없다.

이 개선안은 정책·계약 확정 단계까지이며, 실제 코드 반영(`main.tf`, `variables.tf`, `variables-context.tf`, `outputs.tf`, `routes.tf`, `route53-zone.tf` 수정, README 표 갱신, `examples`/`tests` 작성)은 `terraform-aws-module-engineer` 에게 위임한다.

---

## 6. tfmodule-context 의존성 정책 — v1.3.6 이상 필수

### 6.1 정책 확정

이 모듈은 **[tfmodule-context](https://github.com/oniops/tfmodule-context) v1.3.6 이상**의 출력 `context` 를 전제로 설계를 확정한다. `v1.3.6` 미만 버전과의 조합은 지원 대상에서 제외한다.

### 6.2 현재 상태 진단 — 버전 문자열 중복·불일치

코드베이스 전수 조사 결과 tfmodule-context 참조 버전 문자열이 **세 곳에 서로 다른 값으로** 흩어져 있었다(교정 전 상태).

| 위치 | 참조 버전 | 비고 |
| --- | --- | --- |
| `README.md` (Usage 예시, `module "ctx" { source = ...?ref=v1.3.5 }`) | `v1.3.5` | 이번 문서 반영 시 `v1.3.6` 으로 교정(README.md) |
| `variables-context.tf` (description 첫 줄) | `v1.3.5` | 코드 반영은 engineer 위임(이번 작업은 문서 표기만 정리) |
| `target/demo/main.tf`, `target/demo/README.md` | `v1.3.4` | README 와 **불일치** — 실제로 이미 버전 드리프트가 발생해 있었음. 코드 산출물이므로 engineer 위임 |
| kylo pcx `main.tf`(구 참조 구현) | `v1.3.4` | 참고용 |

이는 "참조 버전은 모듈의 설계 문서 한곳에서만 정의하고 다른 곳에서 다시 적지 않는다"를 위반한 실제 사례였다. **판정: 정책 위반. 단일 소스화 필요.**

### 6.3 단일 소스 지정

이 문서(`REQUIREMENTS.md` §6)를 tfmodule-context 참조 버전의 **단일 소스**로 지정한다. README·`variables-context.tf`·`target/demo`·`examples/`·`tests/` 등 모든 구현 산출물은 아래 규칙을 따른다.

- 모든 산출물에서 tfmodule-context 를 `source = "git::https://github.com/oniops/tfmodule-context.git?ref=v1.3.6"` (또는 그 이상의 패치/마이너 태그)로만 참조한다.
- 구체적인 상한은 두지 않는다(`>= v1.3.6` 의미로 사용하되 Terraform 모듈 `source` 의 `?ref=` 는 정확한 태그 하나만 지정 가능하므로, 실제로는 "이 저장소가 검증한 최신 안정 태그"를 박아 넣고 그 값이 `v1.3.6` 이상이어야 한다는 규칙으로 운용한다).
- 버전을 올릴 때는 이 문서의 표(§6.2)만 고치고, 그 값을 README·코드·예제가 그대로 인용하도록 한다(문서 간 복붙 금지, 생성 스크립트/terraform-docs 로 README 를 생성하는 경우 이 표를 입력으로 삼는다).

### 6.4 강제·표기 방법

버전 하한(`v1.3.6`)을 강제하는 방법은 Terraform 언어의 근본적 한계(모듈은 자신을 호출하는 상위 모듈의 소스 태그를 런타임에 알 수 없다) 때문에 **구조적(타입) 강제**와 **프로세스적 강제**를 병행한다.

| 강제 계층 | 방법 | 한계/주의 |
| --- | --- | --- |
| 문서 강제 | `variables-context.tf` 의 `variable "context"` `description` 첫 줄에 "tfmodule-context v1.3.6 이상 출력 전제"를 명시(§4.1 HCL 반영됨) | 호출자가 읽지 않으면 강제되지 않음 |
| 구조(타입) 강제 — 조건부 채택 | v1.3.6 에서 신규로 추가된 출력 필드가 있고 그 필드가 이 모듈에 실제로 필요하다면, 그 필드를 `context` 객체 타입에 **필수(non-optional)** 로 추가한다. 그러면 v1.3.6 미만 버전의 `context` 를 넘길 때 Terraform 타입 검증이 "필수 속성 누락"으로 plan 을 구조적으로 실패시킨다 | tfmodule-context v1.3.6 CHANGELOG 확인이 선행되어야 함. **engineer 가 tfmodule-context 저장소를 조회해 실제 diff 를 확인**해야 한다. 이 모듈이 실제로 쓰지 않는 필드를 오직 버전 강제 목적만으로 추가하는 것은 "리소스에 연결되지 않는 입력 변수를 두지 않는다" 정책 위반이므로, **기능적으로 필요한 필드가 없다면 이 계층은 적용하지 않는다**(ARCHITECTURE.md DECISION D-007) |
| 프로세스(CI) 강제 | 저장소 CI 에 아래와 같은 grep 가드를 추가해 `v1.3.0`~`v1.3.5` 이하 또는 버전 표기가 없는 tfmodule-context 참조가 커밋되면 실패시킨다 | engineer 구현·CI 통합 사항(§6.5 위임) |
| 릴리스 리뷰 강제 | 이 모듈을 새 버전으로 태깅하기 전, PR 체크리스트에 "tfmodule-context 참조 버전이 이 문서의 §6.3 값과 일치하는가"를 포함 | devops-engineer/platform-engineer 와 조율 |

CI 가드 예시(engineer 가 구현):

```shell
#!/usr/bin/env bash
# scripts/check-tfmodule-context-version.sh
set -euo pipefail

MIN_VERSION="v1.3.6"
PATTERN='tfmodule-context\.git\?ref=v([0-9]+)\.([0-9]+)\.([0-9]+)'

fail=0
while IFS=: read -r file version; do
  # version 문자열을 MIN_VERSION 과 semver 비교(major.minor.patch)
  if [[ "$(printf '%s\n%s\n' "$MIN_VERSION" "$version" | sort -V | head -n1)" != "$MIN_VERSION" ]]; then
    echo "ERROR: $file references tfmodule-context $version, which is older than the required $MIN_VERSION."
    fail=1
  fi
done < <(grep -rEo "$PATTERN" --include='*.tf' --include='*.md' . | sed -E 's#.*ref=(v[0-9.]+).*#&#')

exit "$fail"
```

### 6.5 검증 방법(engineer 실행 책임)

1. `terraform-aws-module-engineer` 는 tfmodule-context `v1.3.6` 태그의 실제 output 스키마를 조회하여, 이 모듈이 쓰는 `name_prefix`/`tags`/`region` 필드의 타입·nullability 가 현재 `variable "context"` 정의와 일치하는지 확인한다.
2. `examples/` 를 추가할 경우(정책상 examples/tests 는 engineer 소유) 반드시 `?ref=v1.3.6` 이상으로 tfmodule-context 를 참조하고, `terraform init && terraform validate` 로 스키마 호환을 확인한다.
3. README·`target/demo`(문서화 시점 기준 `v1.3.4`/`v1.3.5` 참조로 드리프트된 상태)의 참조 버전을 `v1.3.6` 이상으로 일괄 교정한다.
4. §6.4 의 CI 가드 스크립트를 CI 파이프라인에 통합한다.

---

## 7. 검증(`validation`/`precondition`/`postcondition`) 배치표

Terraform `required_version >= 1.5.7` 를 유지하므로(§9 버전 정책 참조), "다른 변수를 참조하는 `validation`"(1.9+ 전용)은 사용하지 않는다. 두 개 이상의 값을 비교하는 검사는 모두 `precondition`/`postcondition` 에 둔다.

| # | 검사 내용 | 대상 | 분류 | 배치 위치 | 상태 |
| --- | --- | --- | --- | --- | --- |
| 1 | `name` 이 `^[a-z0-9][a-z0-9-]*$` 형식 | 단일 변수(`name`) | `validation` | `variable "name"` | 기존 유지 |
| 2 | `requester.routes[*]` 가 `route_table_id`/`route_table_name` 중 정확히 하나 | 단일 변수(`requester`) 내부 항목 간 비교 | `validation` | `variable "requester"` | 기존 유지 |
| 3 | `requester.routes[*].destination_cidr_block` 유효 IPv4 CIDR | 단일 변수(`requester`) | `validation` | `variable "requester"` | 기존 유지 |
| 4 | `accepter.account_id` 가 `null` 이거나 12자리 숫자 | 단일 변수(`accepter`) | `validation` | `variable "accepter"` | **수정**(§4.2, `null` 허용 조건 추가) |
| 5 | `accepter.routes[*]` 가 `route_table_id`/`route_table_name` 중 정확히 하나 | 단일 변수(`accepter`) | `validation` | `variable "accepter"` | 기존 유지 |
| 6 | `accepter.routes[*].destination_cidr_block` 유효 IPv4 CIDR | 단일 변수(`accepter`) | `validation` | `variable "accepter"` | 기존 유지 |
| 7 | `tags` 에 `Name` 키 미포함 | 단일 변수(`tags`) | `validation` | `variable "tags"` | 기존 유지 |
| 8 | `context.name_prefix != null` | 단일 변수(`context`) | `validation` | `variable "context"` | **신규**(§4.1) |
| 9 | `context.tags != null` | 단일 변수(`context`) | `validation` | `variable "context"` | **신규** |
| 10 | `context.region != null` | 단일 변수(`context`) | `validation` | `variable "context"` | **신규** |
| 11 | `accepter.account_id`(명시 시) == `aws.accepter` provider 의 실제 계정 ID | 변수 `accepter.account_id` ↔ `data.aws_caller_identity.accepter` 결과 비교 | `postcondition` | `data.aws_caller_identity.accepter`(값을 만들어내는 데이터 소스 자신 — 참조 관계상 나중에 오는 쪽) | **신규**(§4.3) |
| 12 | `accepter.region`(명시 시) == `aws.accepter` provider 의 실제 리전 | 변수 `accepter.region` ↔ `data.aws_region.accepter` 의 `self.region` 비교(aws provider v6 에서 `aws_region.name` 은 deprecated 이므로 `self.region` 을 쓴다) | `postcondition` | `data.aws_region.accepter` | **신규** |
| 13 | `route_table_name` 지정 시 대상 VPC 안에 `Name` 태그 일치 Route Table 이 정확히 1개 | `data.aws_route_table` 조회 결과(0개/2개 이상이면 provider native 오류) | data source native 실패(모듈이 재검사하지 않음) | — | 기존 유지. `description` 에 "일치하는 Route Table 이 없거나 둘 이상이면 plan 실패"를 명시(README 에 이미 기술) |
| 14 | `private_domain` 지정 시 자기 VPC 에 연결된 동일 이름의 Private Hosted Zone 존재 | `data.aws_route53_zone` 조회 결과 | data source native 실패 | — | 기존 유지, `description` 에 명시 |
| 15 | 수락 측 Route Table 에 이미 동일 목적지 CIDR 경로가 존재 | AWS API(apply 단계 거부) | 모듈이 검사하지 않음 — AWS 가 apply 에서 거부하는 조건 | — | `routes` 항목 `description` 에 그 사실을 명시(README 에 이미 기술, `variables.tf` 의 `routes` 필드 설명에도 동일 문구 반영하도록 engineer 에 위임) |

| 16 | `fullname` 이 `null` 이거나 `^[a-z0-9][a-z0-9-]*$` 형식 | 단일 변수(`fullname`) | `validation` | `variable "fullname"` | **신규**(§4.6, DECISION D-009) |

행 번호는 추가 순서다(기존 1~15 번의 번호를 유지하기 위해 신규 검사는 표 끝에 붙인다). 16 번은 성격상 1 번(`name` 형식)과 같은 분류다.

표 갱신 규칙: 검사를 추가·변경하는 모든 PR 은 이 표를 같은 커밋에서 갱신해야 한다.

---

## 8. 테스트·검증 요구사항 (engineer 위임)

정책 스페셜리스트가 요구하는 테스트 범위이며, 구현·실행은 `terraform-aws-module-engineer` 소유다.

### 8.1 필수 시나리오

| 시나리오 | 검증 목표 |
| --- | --- |
| 최소 입력(라우트·Private Domain 없음) | `requester`/`accepter` 의 `routes`, `private_domain` 을 생략해도 Peering 연결과 DNS 옵션까지만 생성되고 나머지 리소스는 0개(`for_each = {}`, `count = 0`) |
| `route_table_id` 방식 | 지정한 ID 로 `aws_route` 가 생성됨 |
| `route_table_name` 방식 | `data.aws_route_table` 조회 후 그 ID 로 `aws_route` 생성됨. 일치 0개/2개 이상 케이스는 `terraform plan` 실패로 확인(실제 AWS 계정 필요 시 `tests/`에서 mock 불가 영역은 문서화로 대체) |
| 양방향 Private Hosted Zone | `requester.private_domain`, `accepter.private_domain` 을 모두 지정했을 때 양쪽 Authorization/Association 4개 리소스 모두 생성 |
| `accepter.account_id`/`region` 생략 | `local.accepter_account_id`/`local.accepter_region` 이 provider 실제 값과 일치, 출력 `accepter_account_id`/`accepter_region` 에 반영 |
| `accepter.account_id`/`region` 명시 + provider 와 불일치 | `terraform plan` 이 §7 표 11·12 의 `postcondition` 메시지로 실패 |
| `routes` 항목 추가 | 기존 `routes` 키의 `aws_route` 에 변경(`~`)·재생성(`-/+`) 0건, 신규 키만 추가(`+`) — 멱등성 정책 검증의 핵심 |
| `routes` 항목 제거 | 제거된 키의 `aws_route` 만 삭제(`-`), 나머지 키 변경 0건 |
| `fullname` 미지정 | `Name` 태그와 출력 `name` 이 기존 규칙 `<name_prefix>-<name>-pcx` 와 완전히 동일(하위 호환) |
| `fullname` 지정 | `Name` 태그와 출력 `name` 이 `fullname` 값 그대로이며, 양쪽 태그 지원 리소스에 같은 값이 적용됨. 다른 태그 키의 병합 순서는 불변 |
| `fullname` 형식 오류(대문자·밑줄·공백·빈 문자열) | §7 표 16 의 `validation` 으로 plan 실패 |
| 기존 상태에 `fullname` 신규 지정 | 태그 지원 리소스 2개만 in-place 갱신(`~`), 경로·존 연결·Peering 연결에 재생성(`-/+`) 0건 |
| `tags` 에 `Name` 포함 | `terraform plan` 이 검증 메시지로 실패 |
| `context.region = null` 주입(단위 테스트 수준) | §7 표 10 의 `validation` 으로 plan 실패 |
| 같은 계정·리전(`aws.accepter = aws`) 호출 | 정상 동작, `data.aws_caller_identity.accepter` 가 요청 계정과 동일 값을 반환해도 문제 없음 |

### 8.2 `terraform test`/plan 멱등성 검증

- `terraform test`(`.tftest.hcl`) 또는 동등한 plan-only 검증으로 위 시나리오를 자동화한다.
- 항목 추가·제거 케이스는 "before/after 두 번의 plan"을 비교해 `~`/`-/+` 0건을 기계적으로 확인한다.
- `configuration_aliases`(`aws.accepter`) 를 가진 모듈은 루트 단독 `validate`가 불가능하므로, README §검증에 기술된 임시 provider 스택 패턴을 `tests/` 하위의 고정된 fixture 로 옮겨 반복 검증 가능하게 한다.

### 8.3 스캔

- 보안 스캔(`tfsec`/`checkov` 등)에서 `aws_vpc_peering_connection*`, `aws_route*`, `aws_route53_*` 리소스에 대한 오탐/실탐 여부를 engineer 가 판단하고, 정책상 의도된 예외(예: 태그 미지원 리소스)는 스캔 설정에 주석으로 근거를 남긴다.
- 비용 스캔(`infracost` 등)은 이 모듈이 시간당 과금 리소스를 생성하지 않음을 재확인하는 용도로 사용하고, Cross-Region 데이터 전송 비용은 정적 스캔으로 잡히지 않으므로 ARCHITECTURE.md §7 의 `description` 명시로 대체한다.

---

## 9. Terraform/Provider 버전 정책

| 항목 | 값 | 근거 |
| --- | --- | --- |
| `required_version` 하한 | `>= 1.5.7`(변경 없음) | 이번 개선안의 모든 신규 검사(§7 표 8~12)는 `validation`(단일 변수) 또는 `lifecycle.postcondition`(데이터 소스)으로 배치되며 둘 다 Terraform 1.5 에서 지원된다. "다른 변수를 참조하는 `validation`"(1.9+ 전용) 은 쓰지 않으므로 하한을 올릴 이유가 없다 |
| `aws` provider 버전 | `>= 6.0, < 7.0`(변경 없음) | `data "aws_caller_identity"`, `data "aws_region"` 은 AWS provider 전 버전대에서 안정적으로 제공되는 데이터 소스이므로 상한 변경 불필요 |
| `versions.tf` 외 `terraform {}` 블록 | 두지 않는다(현행 준수) | 정책 |
| 검증 도구(CI 의 최신 `terraform` CLI 등)가 더 높은 버전을 요구하더라도 | `required_version` 하한을 올리지 않는다 | 정책 명시 사항 |

**향후 하한을 올려야 하는 조건(참고용, 지금은 해당 없음):** `accepter.account_id`/`region` 외에 진짜로 "여러 변수를 동시에 참조하는 `variable` 레벨 `validation`"이 필요해지는 요구가 생기면, 그때 `required_version`을 `>= 1.9.0` 으로 올리고 §7 표의 해당 검사들을 `precondition`에서 `validation`으로 재분류하는 것을 검토한다. 지금은 그런 요구가 없으므로 하한을 유지한다.

---

## 10. Definition of Done 체크리스트

이 문서가 확정한 정책을 기준으로, `terraform-aws-module-engineer` 구현물이 통과해야 하는 판정 기준은 다음과 같다.

- [ ] 모든 리소스 이름/`Name` 태그가 `context.name_prefix`에서만 파생(변경 없음, 기존 준수 확인만 필요)
- [ ] 태그 병합이 `merge(context.tags, tags, {Name})` 순서로 교정됨(§4.5, DECISION D-004)
- [ ] `accepter.account_id`/`region`이 `optional`로 전환되고 provider 파생 로직과 `postcondition` 2건이 구현됨(§4.2, §4.3, DECISION D-002, D-003)
- [ ] `context.name_prefix`/`tags`/`region` null 방어 `validation` 3건 추가됨(§4.1, DECISION D-006)
- [ ] `outputs.tf`에 `accepter_account_id`, `accepter_region` 추가됨(§4.4)
- [ ] README, `variables-context.tf`, `target/demo`의 tfmodule-context 참조가 모두 `v1.3.6` 이상으로 일치함(§6, DECISION D-001)
- [ ] CI에 tfmodule-context 버전 grep 가드가 통합됨(§6.4)
- [ ] `routes`/`accepter.routes`/`requester.routes` 항목 추가·제거 plan에서 다른 키 변경·재생성 0건이 `terraform test`로 확인됨(§8.1, §8.2)
- [ ] `accepter.account_id`/`region` 명시값과 provider 불일치 시 plan이 §4.3의 메시지로 실패함이 테스트로 확인됨
- [ ] 선택 입력 `fullname` 이 `optional(null)` 로 추가되고, 미지정 시 `Name` 태그가 기존과 동일함이 `terraform test` 로 확인됨(§4.6, DECISION D-009)
- [ ] `fullname` 의 형식 `validation`(§7 표 16)이 구현되고 실패 케이스가 테스트로 확인됨
- [ ] `fullname` 신규 지정 plan 에서 재생성(`-/+`) 0건이 기계적으로 확인됨(`scripts/check-idempotency.sh` 의 `set_fullname_plan`)
- [ ] 이번 변경 전체가 MINOR로 태깅되고, README Input/Output 표가 같은 변경에서 갱신됨(§5 참조)

이 판정이 모두 충족되면 정책 관점의 승인이 완료된 것으로 본다. 실행(코드 반영, 테스트 실행, README 재생성, 릴리스 태그)은 `terraform-aws-module-engineer`의 책임이며, 그 결과물은 이 체크리스트를 근거로 다시 판정한다.
