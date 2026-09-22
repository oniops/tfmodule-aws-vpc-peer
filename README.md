# AWS VPC Peering Terraform module

두 VPC 사이의 VPC Peering 연결을 구성하는 Terraform 모듈입니다. 요청(requester) VPC 와 수락(accepter) VPC 가 서로 다른 AWS 계정·리전에 있어도 동작하며, Peering 요청·수락, DNS 해석 옵션, 양쪽 Route Table 경로, Route53 Private Hosted Zone 교차 연결을 한 번의 호출로 만듭니다.

모듈 인스턴스 하나가 Peering 연결 하나를 담당합니다. 요청 VPC 는 기본 `aws` provider, 수락 VPC 는 `aws.accepter` provider 로 다루며, 수락이 끝나 연결이 `active` 가 된 뒤 옵션·경로·존 연결을 만듭니다.

양쪽 VPC 는 이 모듈이 만들지 않습니다. VPC ID, Route Table, 상대 VPC CIDR 은 호출자가 값을 직접 적으며, Route Table 은 ID(`route_table_id`) 또는 `Name` 태그(`route_table_name`) 중 편한 쪽으로 지정합니다.

## 문서

이 README 는 빠른 시작과 실제 호출 예시를 다루는 진입점입니다. 그 외 문서는 성격에 따라 나뉘어 있습니다.

- [ARCHITECTURE.md](requirements/ARCHITECTURE.md) — 이 모듈이 **왜** 이렇게 설계되었는지(아키텍처 개요, 모듈 경계, Hub & Spoke 패턴, 구(kylo pcx) 구현 대조 분석, 네이밍·태그·보안 기본값 설계 근거, 설계 결정 기록 DECISIONS)
- [REQUIREMENTS.md](requirements/REQUIREMENTS.md) — 이 모듈이 **무엇을** 충족해야 하는지(기능 요구사항, 입력·출력 계약, 변수 구조 개선안, tfmodule-context 버전 정책, 검증 배치표, 테스트 요구사항, 버전 정책, Definition of Done)

## Usage

모듈에는 `provider` 블록이 없습니다. 호출자가 `providers` 로 요청 VPC 의 `aws` 와 수락 VPC 의 `aws.accepter` 를 반드시 넘겨야 합니다.

수락 계정 ID 와 리전은 `aws.accepter` provider 가 이미 알고 있는 값이므로 **입력하지 않는 것이 기본**입니다. 모듈이 `data.aws_caller_identity`·`data.aws_region` 으로 provider 에서 직접 읽어 씁니다. 실제로 사용된 값은 출력 `accepter_account_id`, `accepter_region` 으로 확인합니다. 값을 명시하고 싶다면 [계정 ID·리전 명시](#계정-id리전-명시선택)를 참조하세요.

### Hub & Spoke 아키텍처 샘플

아래 예시는 공유 서비스를 두는 Hub VPC `fruithub-vpc` 가 요청자(requester)가 되어 두 Spoke VPC 와 각각 Peering 을 맺는 구성입니다. Peering 은 전이 라우팅을 지원하지 않으므로 Hub 와 Spoke 는 통신하지만 Spoke 끼리(`apple-vpc` ↔ `banana-vpc`)는 통신하지 않습니다. Spoke 마다 모듈을 한 번씩 호출합니다.

| 역할 | VPC | 계정 | 리전 | CIDR | Route Table 지정 방식 |
| --- | --- | --- | --- | --- | --- |
| Hub (requester) | `fruithub-vpc` | `111111111111` | `ap-northeast-2` | `10.100.0.0/16` | Spoke 예시별로 다름 |
| Spoke (accepter) | `apple-vpc` | `222222222222` | `ap-northeast-2` | `10.101.0.0/16` | `route_table_name` |
| Spoke (accepter) | `banana-vpc` | `333333333333` | `us-east-1` | `10.102.0.0/16` | `route_table_id` |

```text
                        ┌──────────────────────────────┐
                        │ fruithub-vpc (Hub)           │
                        │ 111111111111  ap-northeast-2 │
                        │ 10.100.0.0/16                │
                        └───────┬──────────────┬───────┘
        fruithub-an2p-apple-pcx │              │ fruithub-an2p-banana-pcx
                ┌───────────────▼─────┐    ┌───▼──────────────────────┐
                │ apple-vpc (Spoke)   │    │ banana-vpc (Spoke)       │
                │ 222222222222        │    │ 333333333333             │
                │ ap-northeast-2      │    │ us-east-1                │
                │ 10.101.0.0/16       │    │ 10.102.0.0/16            │
                └─────────────────────┘    └──────────────────────────┘
```

#### 공통: context 와 provider

Hub 계정에서 Terraform 을 실행하고, Spoke 계정에는 [수락 계정 IAM 역할](#수락-계정-iam-역할)을 미리 만들어 둡니다.

```hcl
# Hub 의 context. name_prefix 는 fruithub-an2p 가 된다.
# tfmodule-context는 v1.3.6 이상을 참조해야 합니다(requirements/REQUIREMENTS.md §6).
module "ctx" {
  source      = "git::https://github.com/oniops/tfmodule-context.git?ref=v1.3.6"
  context     = var.context # project = "fruithub", region = "ap-northeast-2", environment = "Production", ...
  team        = var.team
  cost_center = var.cost_center
}

# Hub VPC 의 provider. 리전은 context.region 과 같다.
provider "aws" {
  region = module.ctx.region
}

# Spoke apple-vpc 의 provider
provider "aws" {
  alias  = "apple"
  region = "ap-northeast-2"
  assume_role {
    role_arn    = "arn:aws:iam::222222222222:role/VpcPeeringAccepterRole"
    external_id = var.peer_external_id
  }
}

# Spoke banana-vpc 의 provider
provider "aws" {
  alias  = "banana"
  region = "us-east-1"
  assume_role {
    role_arn    = "arn:aws:iam::333333333333:role/VpcPeeringAccepterRole"
    external_id = var.peer_external_id
  }
}
```

#### fruithub-vpc → apple-vpc: `route_table_name` 방식

양쪽 Route Table 을 `Name` 태그로 지정합니다. 모듈이 각 VPC 안에서 `Name` 태그가 일치하는 Route Table 을 조회하므로 ID 를 미리 알아낼 필요가 없습니다. 양쪽 `private_domain` 을 함께 지정해 Hub 는 `apple.internal` 을, apple 은 `fruithub.internal` 을 해석할 수 있게 합니다.

```hcl
module "pcx_apple" {
  source = "git::https://github.com/oniops/tfmodule-aws-vpc-peer.git?ref=<tag>"

  providers = {
    aws          = aws       # Hub   : fruithub-vpc
    aws.accepter = aws.apple # Spoke : apple-vpc
  }

  context = module.ctx.context
  name    = "apple" # Name 태그 = fruithub-an2p-apple-pcx
  # fullname 을 적으면 Name 태그를 그 값으로 대신할 수 있습니다(아래 fullname 절 참조).
  # fullname = "fruithub-an2p-to-apple-an2p-pcx"

  # Hub 측
  requester = {
    vpc_id         = "vpc-0aaaaaaaaaaaaaaaa"
    private_domain = "fruithub.internal" # Hub 의 Private Hosted Zone 을 apple-vpc 에 연결
    # Hub Route Table -> apple-vpc CIDR
    routes = {
      pri-a1 = { route_table_name = "fruithub-an2p-pri-a1-rt", destination_cidr_block = "10.101.0.0/16" }
      pri-c1 = { route_table_name = "fruithub-an2p-pri-c1-rt", destination_cidr_block = "10.101.0.0/16" }
    }
  }

  # Spoke 측. 계정 ID(222222222222)·리전(ap-northeast-2)은 aws.apple provider 에서 파생하므로 적지 않는다.
  accepter = {
    vpc_id         = "vpc-0bbbbbbbbbbbbbbbb"
    private_domain = "apple.internal" # apple 의 Private Hosted Zone 을 fruithub-vpc 에 연결
    # apple-vpc Route Table -> Hub CIDR
    routes = {
      pri-a1 = { route_table_name = "apple-an2p-pri-a1-rt", destination_cidr_block = "10.100.0.0/16" }
      pri-c1 = { route_table_name = "apple-an2p-pri-c1-rt", destination_cidr_block = "10.100.0.0/16" }
    }
  }

  tags = {
    Spoke = "apple"
  }
}
```

#### fruithub-vpc → banana-vpc: `route_table_id` 방식

양쪽 Route Table 을 ID 로 직접 지정합니다. 리전이 다른 Spoke 이지만 리전은 `aws.banana` provider(`us-east-1`)에서 파생하므로 모듈 입력에는 적지 않습니다. Private Hosted Zone 연결은 생략한 예시입니다.

```hcl
module "pcx_banana" {
  source = "git::https://github.com/oniops/tfmodule-aws-vpc-peer.git?ref=<tag>"

  providers = {
    aws          = aws        # Hub   : fruithub-vpc
    aws.accepter = aws.banana # Spoke : banana-vpc
  }

  context = module.ctx.context
  name    = "banana" # Name 태그 = fruithub-an2p-banana-pcx

  # Hub 측
  requester = {
    vpc_id = "vpc-0aaaaaaaaaaaaaaaa"
    # Hub Route Table -> banana-vpc CIDR
    routes = {
      pri-a1 = { route_table_id = "rtb-0aaaaaaaaaaaaaaa1", destination_cidr_block = "10.102.0.0/16" }
      pri-c1 = { route_table_id = "rtb-0aaaaaaaaaaaaaaa2", destination_cidr_block = "10.102.0.0/16" }
    }
  }

  # Spoke 측. 계정 ID(333333333333)·리전(us-east-1)은 aws.banana provider 에서 파생한다.
  accepter = {
    vpc_id = "vpc-0ccccccccccccccc"
    # banana-vpc Route Table -> Hub CIDR
    routes = {
      pub = { route_table_id = "rtb-0ccccccccccccccc1", destination_cidr_block = "10.100.0.0/16" }
      pri = { route_table_id = "rtb-0ccccccccccccccc2", destination_cidr_block = "10.100.0.0/16" }
    }
  }

  tags = {
    Spoke = "banana"
  }
}
```

#### 출력 참조

```hcl
output "pcx_ids" {
  value = {
    apple  = module.pcx_apple.id
    banana = module.pcx_banana.id
  }
}

# 실제로 사용된 수락 계정·리전을 확인한다.
output "pcx_apple_accepter" {
  value = {
    account_id = module.pcx_apple.accepter_account_id # "222222222222"
    region     = module.pcx_apple.accepter_region     # "ap-northeast-2"
  }
}
```

### 계정 ID·리전 명시(선택)

`accepter.account_id`, `accepter.region` 은 선택 입력입니다. 생략하면 `aws.accepter` provider 에서 파생하고, 적으면 그 값을 그대로 씁니다. 다만 **적은 값이 provider 의 실제 계정·리전과 다르면 plan 이 실패합니다**. 값을 적는 것은 "이 provider 는 반드시 이 계정·이 리전이어야 한다"는 재확인(assertion)으로만 의미가 있습니다.

```hcl
  accepter = {
    account_id = "222222222222"   # aws.apple 이 실제로 assume 하는 계정과 달라야 하면 plan 실패
    region     = "ap-northeast-2" # aws.apple provider 의 리전과 달라야 하면 plan 실패
    vpc_id     = "vpc-0bbbbbbbbbbbbbbbb"
  }
```

```text
Error: Resource postcondition failed
  on main.tf line 24, in data "aws_caller_identity" "accepter":
accepter.account_id (999988887777) does not match the AWS account assumed by
the aws.accepter provider (222222222222).
```

### 연결 흐름이 드러나는 이름 지정(`fullname`, 선택)

`Name` 태그의 기본값은 `<name_prefix>-<name>-pcx` 입니다. `name_prefix` 는 요청(requester) 측 `context` 에서 오므로 기본 규칙만으로는 **어느 VPC 에서 어느 VPC 로 향하는 연결인지**가 드러나지 않습니다. 이때 `fullname` 에 이름을 직접 적으면 `Name` 태그가 그 값 **그대로** 됩니다.

```hcl
module "pcx_apple" {
  # ...
  context  = module.ctx.context
  name     = "apple"                              # 여전히 필수. 호출자 코드 안에서 이 연결을 식별하는 키
  fullname = "fruithub-an2p-to-apple-an2p-pcx"    # Name 태그 = 이 값 그대로
}
```

| `fullname` | `Name` 태그 |
| --- | --- |
| 생략(기본, `null`) | `<name_prefix>-<name>-pcx` — 예: `fruithub-an2p-apple-pcx` |
| 지정 | 적은 값 그대로 — 예: `fruithub-an2p-to-apple-an2p-pcx` |

- 선택 입력이며 기본값은 `null` 입니다. 적지 않으면 기존과 완전히 같은 이름이 나옵니다(하위 호환).
- 모듈이 아무 접두어·접미어도 붙이지 않습니다. `-pcx` 접미어가 필요하면 값에 직접 포함하세요.
- `name` 은 `fullname` 을 적어도 계속 필수입니다. `name` 은 호출자 구성 안에서 이 연결을 가리키는 키로 남고, `fullname` 은 `Name` 태그만 덮어씁니다.
- 문자 규칙은 `name` 과 같습니다(소문자·숫자로 시작, 소문자·숫자·하이픈만). 위반하면 plan 이 실패합니다.
- `fullname` 은 어떤 리소스 주소나 `for_each` 키에도 쓰이지 않습니다. 기존 연결에 `fullname` 을 새로 적어도 `Name` 태그만 in-place 로 갱신되며(`~`) 재생성(`-/+`)은 일어나지 않습니다.

### Route Table 지정 방식

`routes` 의 각 항목은 Route Table 하나와 목적지 CIDR 하나입니다. Route Table 은 `route_table_id` 또는 `route_table_name` 중 정확히 하나로 지정하며, 한 `routes` 안에서 두 방식을 섞어 써도 됩니다.

| 방식 | 동작 | 예시 |
| --- | --- | --- |
| `route_table_id` | 값을 그대로 `aws_route.route_table_id` 에 쓴다 | [fruithub-vpc → banana-vpc](#fruithub-vpc--banana-vpc-route_table_id-방식) |
| `route_table_name` | 같은 쪽 VPC 안에서 `Name` 태그가 일치하는 Route Table 을 조회한다. 일치하는 Route Table 이 없거나 둘 이상이면 plan 이 실패한다 | [fruithub-vpc → apple-vpc](#fruithub-vpc--apple-vpc-route_table_name-방식) |

보조 CIDR 을 가진 VPC 와 연결할 때는 같은 Route Table 에 CIDR 마다 항목을 하나씩 나열합니다.

```hcl
    routes = {
      pri-a1     = { route_table_name = "fruithub-an2p-pri-a1-rt", destination_cidr_block = "10.101.0.0/16" }
      pri-a1-2nd = { route_table_name = "fruithub-an2p-pri-a1-rt", destination_cidr_block = "10.111.0.0/16" }
    }
```

### Private Hosted Zone 교차 연결

`private_domain` 을 지정한 쪽이 소유한 Route53 Private Hosted Zone 을 상대 VPC 에 연결해, 상대 VPC 의 리소스가 그 존의 레코드를 조회할 수 있게 합니다. 두 방향을 각각 독립적으로 켤 수 있으며, apple-vpc 예시는 두 방향을 모두 켠 경우입니다.

| 입력 | 존 조회 | 인가 | 연결 | 결과 |
| --- | --- | --- | --- | --- |
| `accepter.private_domain` (`apple.internal`) | `aws.accepter` 에서 `accepter.vpc_id` 에 연결된 존을 이름으로 조회 | `aws.accepter` 가 `requester.vpc_id`(리전 `context.region`)를 인가 | `aws` 가 Hub VPC 에 존을 연결 | Hub 가 `apple.internal` 을 해석한다 |
| `requester.private_domain` (`fruithub.internal`) | `aws` 에서 `requester.vpc_id` 에 연결된 존을 이름으로 조회 | `aws` 가 `accepter.vpc_id`(리전 `accepter.region`)를 인가 | `aws.accepter` 가 Spoke VPC 에 존을 연결 | apple 이 `fruithub.internal` 을 해석한다 |

- 존은 `name`, `private_zone = true`, `vpc_id` 로 조회하므로 지정한 이름의 Private Hosted Zone 이 자기 VPC 에 이미 연결되어 있어야 합니다.
- 존 연결과 별개로 상대 VPC 리소스의 퍼블릭 DNS 호스트 이름을 프라이빗 IP 로 해석하려면 `allow_remote_vpc_dns_resolution`(기본 `true`)을 켭니다.

### 같은 계정·리전 안의 연결

Hub 와 같은 계정·리전에 있는 Spoke 는 두 항목에 같은 provider 를 넘깁니다.

```hcl
module "pcx_cherry" {
  source    = "git::https://github.com/oniops/tfmodule-aws-vpc-peer.git?ref=<tag>"
  providers = { aws = aws, aws.accepter = aws }

  context = module.ctx.context
  name    = "cherry"

  # Hub 측 fruithub-vpc (10.100.0.0/16)
  requester = {
    vpc_id = "vpc-0aaaaaaaaaaaaaaaa"
    routes = { pri-a1 = { route_table_name = "fruithub-an2p-pri-a1-rt", destination_cidr_block = "10.103.0.0/16" } }
  }

  # Spoke 측 cherry-vpc (10.103.0.0/16). 같은 provider 를 넘겼으므로 계정·리전은 Hub 와 같은 값으로 파생된다.
  accepter = {
    vpc_id = "vpc-0ddddddddddddddd"
    routes = { pri-a1 = { route_table_id = "rtb-0ddddddddddddddd1", destination_cidr_block = "10.100.0.0/16" } }
  }
}
```

### 수락 계정 IAM 역할

`aws.accepter` provider 가 수락 계정에서 Assume 하는 역할은 미리 만들어 두어야 합니다. `templates/` 디렉터리에 그 역할의 신뢰 정책과 권한 정책 템플릿이 있습니다.

| 파일 | 용도 | 치환 변수 |
| --- | --- | --- |
| `templates/vpc-pcx-caa-trust.tftpl` | 신뢰 정책. 요청 계정의 IAM 주체가 `sts:ExternalId` 조건으로 `sts:AssumeRole` 한다 | `hub_iam_administrators`(Principal ARN 목록), `hub_assume_role_external_id` |
| `templates/vpc-pcx-caa-policy.tftpl` | 권한 정책. Peering 수락·옵션 변경, Route 생성·교체·삭제, Route53 Hosted Zone 인가·연결 권한 | 없음 |

권한 정책 템플릿이 허용하는 액션 중 이 모듈이 수락 측에서 쓰는 것은 다음과 같습니다.

| 액션 | 쓰는 리소스 |
| --- | --- |
| `ec2:DescribeVpcPeeringConnections`, `ec2:AcceptVpcPeeringConnection`, `ec2:CreateTags` | `aws_vpc_peering_connection_accepter.this` |
| `ec2:ModifyVpcPeeringConnectionOptions` | `aws_vpc_peering_connection_options.accepter` |
| `ec2:DescribeRouteTables` | `data.aws_route_table.accepter`, `aws_route.accepter` |
| `ec2:CreateRoute`, `ec2:ReplaceRoute`, `ec2:DeleteRoute` | `aws_route.accepter` |
| `route53:ListHostedZones`, `route53:GetHostedZone`, `route53:ListTagsForResource` | `data.aws_route53_zone.accepter` |
| `route53:ListVPCAssociationAuthorizations`, `route53:CreateVPCAssociationAuthorization`, `route53:DeleteVPCAssociationAuthorization` | `aws_route53_vpc_association_authorization.accepter` |
| `route53:AssociateVPCWithHostedZone`, `route53:DisassociateVPCFromHostedZone` | `aws_route53_zone_association.requester` |

- 수락 계정·리전 파생에 쓰는 `data.aws_caller_identity.accepter` 는 `sts:GetCallerIdentity` 를 호출합니다. 이 API 는 IAM 권한이 필요 없으므로 역할 정책에 추가할 액션이 없습니다. `data.aws_region.accepter` 는 provider 설정과 SDK 내장 리전 메타데이터만 읽으며 AWS API 를 호출하지 않습니다.
- 템플릿의 `acm:*` 액션과 `route53:ListResourceRecordSets` 는 이 모듈이 쓰지 않습니다.
- 이미 만든 Peering 의 태그를 제거하거나 바꾸려면 템플릿에 없는 `ec2:DeleteTags` 가 추가로 필요합니다.
- Peering 삭제는 요청 측(`aws`)에서 수행하므로 수락 역할에 `ec2:DeleteVpcPeeringConnection` 은 필요하지 않습니다.

## Conditional creation

모듈은 `count`, `for_each` 없이 Peering 하나를 만듭니다. 조건부로 만들려면 호출자의 `module` 블록에 `count` 를 둡니다. `providers` 를 넘기는 모듈에도 `count` 를 쓸 수 있습니다.

```hcl
module "pcx_apple" {
  source    = "git::https://github.com/oniops/tfmodule-aws-vpc-peer.git?ref=<tag>"
  count     = var.create_pcx_apple ? 1 : 0
  providers = { aws = aws, aws.accepter = aws.apple }

  # ...
}

output "pcx_apple_id" {
  value = one(module.pcx_apple[*].id)
}
```

## Tags

모든 리소스의 태그는 아래 순서로 병합하며 뒤 단계가 앞 단계의 같은 키를 덮어씁니다. 수락 측 리소스(`aws_vpc_peering_connection_accepter.this`)에도 같은 태그를 적용합니다.

| 순서 | 출처 | 내용 |
| --- | --- | --- |
| 1 | `context.tags` | tfmodule-context 가 만드는 조직 공통 태그 |
| 2 | `tags` | 호출자 커스텀 태그. `context.tags` 의 같은 키를 덮어쓸 수 있다 |
| 3 | 모듈 생성 태그 | `Name` = `fullname` 을 적었으면 그 값, 생략했으면 `<name_prefix>-<name>-pcx`. 항상 마지막 |

`Name` 값 자체는 `fullname` 으로 바꿀 수 있지만(이름 규칙 전용 입력), `tags` 로는 덮어쓸 수 없습니다. `Name` 은 보호 키입니다. 병합의 마지막 단계에서 모듈이 넣으므로 구조적으로 덮어쓸 수 없고, 그와 별개로 `tags` 에 `Name` 을 넣으면 plan 이 실패합니다(이중 방어, [ARCHITECTURE.md §5](requirements/ARCHITECTURE.md#5-태그-정책) DECISION D-004). `aws_route`, `aws_vpc_peering_connection_options`, Route53 인가·연결 리소스는 태그를 지원하지 않습니다.

## Notes

- VPC Peering 은 전이 라우팅을 지원하지 않습니다. A-B, B-C 가 연결되어도 A-C 는 통신하지 못하므로 필요한 쌍마다 모듈을 호출합니다.
- 두 VPC 의 CIDR 이 겹치면 AWS 가 요청을 거부합니다.
- `routes` 의 키가 `aws_route` 의 리소스 키가 됩니다. 항목을 추가·제거해도 다른 키의 경로에는 변경(`~`)이나 재생성(`-/+`)이 생기지 않습니다. 키 이름을 바꾸면 그 경로는 삭제 후 재생성됩니다.
- `name` 이나 `fullname` 을 바꾸면 `Name` 태그만 갱신되며 Peering 연결은 재생성되지 않습니다. `requester.vpc_id`, `accepter.vpc_id` 를 바꾸거나 `aws.accepter` provider 의 계정·리전이 바뀌면 Peering 연결과 그에 딸린 경로·존 연결이 재생성됩니다.
- 모든 `aws_route` 는 `timeouts` 의 `create`, `update`, `delete` 를 `5m` 으로 둡니다.
- 이미 다른 코드로 만든 Peering 을 이 모듈로 옮기면 리소스 주소가 바뀌어 재생성이 계획됩니다. `moved` 블록이나 `terraform state mv` 로 상태를 먼저 옮깁니다.
- 수락 측 Route Table 에 이미 같은 목적지 CIDR 경로가 있으면 `aws_route` 생성이 실패합니다. 기존 경로를 제거하거나 `terraform import` 로 가져옵니다.
- 아래 조건에 걸리면 plan 단계에서 실패합니다.

| 대상 | 조건 | 검사 위치 |
| --- | --- | --- |
| `name` | `^[a-z0-9][a-z0-9-]*$` 에 맞지 않음 | `validation` |
| `fullname` | 값이 있는데 `^[a-z0-9][a-z0-9-]*$` 에 맞지 않음 (생략은 허용) | `validation` |
| `context.name_prefix` | `null` | `validation` |
| `context.tags` | `null` | `validation` |
| `context.region` | `null` | `validation` |
| `accepter.account_id` | 값이 있는데 12자리 숫자가 아님 (생략은 허용) | `validation` |
| `requester.routes[*]`, `accepter.routes[*]` | `route_table_id` 와 `route_table_name` 이 둘 다 없거나 둘 다 있음 | `validation` |
| `requester.routes[*]`, `accepter.routes[*]` | `destination_cidr_block` 이 유효한 IPv4 CIDR 이 아님 | `validation` |
| `tags` | `Name` 키 포함 | `validation` |
| `accepter.account_id` | 명시한 값이 `aws.accepter` provider 의 실제 계정과 다름 | `data.aws_caller_identity.accepter` 의 `postcondition` |
| `accepter.region` | 명시한 값이 `aws.accepter` provider 의 리전과 다름 | `data.aws_region.accepter` 의 `postcondition` |
| `route_table_name` | 같은 VPC 안에 `Name` 태그가 일치하는 Route Table 이 없거나 둘 이상 | data source 조회 실패 |
| `private_domain` | 자기 VPC 에 연결된 같은 이름의 Private Hosted Zone 이 없음 | data source 조회 실패 |

`accepter.routes[*]` 의 목적지 CIDR 경로가 대상 Route Table 에 이미 있으면 plan 은 통과하고 apply 단계에서 AWS 가 거부합니다. 모듈은 이 조건을 미리 검사하지 않습니다.

## Validation

`configuration_aliases` 를 가진 모듈은 루트에서 단독으로 `terraform validate` 할 수 없습니다. 두 provider 를 넘기는 호출 스택이 `tests/fixtures/validate-stack` 에 고정 fixture 로 들어 있으므로 그것을 검증합니다. AWS 자격 증명은 필요하지 않습니다.

```shell
terraform fmt -check -recursive
terraform -chdir=tests/fixtures/validate-stack init -backend=false
terraform -chdir=tests/fixtures/validate-stack validate
```

계약·검증·멱등성 테스트는 `terraform test` 로 실행합니다. `tests/*.tftest.hcl` 은 `mock_provider` 로 두 provider 를 모두 대신하므로 AWS 호출이 없고 아무것도 만들지 않습니다. `mock_provider` 는 Terraform 1.7 이상에서만 동작하므로, 모듈 자체의 하한(`>= 1.5.7`)과 달리 **테스트 실행에는 Terraform 1.7 이상**이 필요합니다.

```shell
terraform init -backend=false
terraform test                     # tests/contract, tests/validation, tests/idempotency
./scripts/check-idempotency.sh     # 항목 추가·제거 plan 에서 다른 키의 ~ / -/+ 가 0건인지 기계적으로 확인
./scripts/check-tfmodule-context-version.sh
```

| 파일 | 확인 내용 |
| --- | --- |
| `tests/contract.tftest.hcl` | 최소 입력, 이름 산식, `fullname` 지정·생략, 태그 병합 순서, 계정·리전 파생, `route_table_id`/`route_table_name` 두 방식, 양방향 Private Hosted Zone, 같은 계정·리전 호출 |
| `tests/validation.tftest.hcl` | 검증 배치표 1~12·16 번이 의도한 자리(`validation` / `postcondition`)에서 실패하는지 |
| `tests/idempotency.tftest.hcl` | `routes` 항목 추가·제거, `private_domain` 켜기, `fullname` 지정에서 다른 리소스가 유지되는지 |
| `scripts/check-idempotency.sh` | 위 plan 들의 실제 action 을 파싱해 의도한 항목 외 `~`·`-/+` 가 0건인지 |

## Requirements

| Name | Version |
| --- | --- |
| terraform | >= 1.5.7 (`terraform test` 실행에는 >= 1.7) |
| aws | >= 6.0, < 7.0 |
| tfmodule-context | >= v1.3.6 ([REQUIREMENTS.md §6](requirements/REQUIREMENTS.md#6-tfmodule-context-의존성-정책--v136-이상-필수) 가 단일 소스) |

## Providers

| Name | Version |
| --- | --- |
| aws | >= 6.0, < 7.0 |
| aws.accepter | >= 6.0, < 7.0 |

## Modules

No modules.

## Resources

| Name | Type |
| --- | --- |
| [aws_vpc_peering_connection.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_peering_connection) | resource |
| [aws_vpc_peering_connection_accepter.this](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_peering_connection_accepter) | resource |
| [aws_vpc_peering_connection_options.requester](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_peering_connection_options) | resource |
| [aws_vpc_peering_connection_options.accepter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/vpc_peering_connection_options) | resource |
| [aws_route.requester](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route.accepter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route) | resource |
| [aws_route53_vpc_association_authorization.requester](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_vpc_association_authorization) | resource |
| [aws_route53_vpc_association_authorization.accepter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_vpc_association_authorization) | resource |
| [aws_route53_zone_association.requester](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_zone_association) | resource |
| [aws_route53_zone_association.accepter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/resources/route53_zone_association) | resource |
| [aws_caller_identity.accepter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/caller_identity) | data source |
| [aws_region.accepter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/region) | data source |
| [aws_route_table.requester](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route_table) | data source |
| [aws_route_table.accepter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route_table) | data source |
| [aws_route53_zone.requester](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |
| [aws_route53_zone.accepter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |

`requester` 접미어 리소스는 `aws`, `accepter` 접미어 리소스는 `aws.accepter` provider 로 만듭니다. 단, `aws_route53_zone_association.requester` 는 요청 측 존을 수락 VPC 에 연결하므로 `aws.accepter` 로, `aws_route53_zone_association.accepter` 는 `aws` 로 만듭니다.

## Inputs

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | :---: |
| context | tfmodule-context(v1.3.6 이상) 출력 객체. `name_prefix`(Name 태그 접두어), `tags`(태그 병합 1단계), `region`(요청 VPC 리전)만 쓰고 나머지 필드는 무시한다. 세 필드가 `null` 이면 plan 이 실패한다. `module.ctx.context` 를 그대로 넘긴다 | <pre>object({<br>  name_prefix  = string<br>  tags         = map(string)<br>  region       = string<br>  region_alias = optional(string)<br>  project      = optional(string)<br>  environment  = optional(string)<br>  env_alias    = optional(string)<br>  owner        = optional(string)<br>  team         = optional(string)<br>  cost_center  = optional(string)<br>  pri_domain   = optional(string)<br>})</pre> | n/a | yes |
| name | Peering 키. `Name` 태그 `<name_prefix>-<name>-pcx` 의 `<name>`. 요청 VPC 안에서 Peering 마다 달라야 하며 소문자·숫자로 시작하고 소문자·숫자·하이픈만 허용한다. `fullname` 을 적어도 계속 필수다 | `string` | n/a | yes |
| fullname | `Name` 태그를 이 값 그대로 덮어쓴다. 생략하면(`null`) 기본 규칙 `<name_prefix>-<name>-pcx` 를 쓴다. 요청 VPC → 수락 VPC 의 연결 흐름이 드러나는 이름을 쓰고 싶을 때 지정한다. 모듈이 접두어·접미어를 붙이지 않으므로 `-pcx` 가 필요하면 값에 포함한다. 문자 규칙은 `name` 과 같다. 리소스 주소·`for_each` 키에는 쓰이지 않는다 | `string` | `null` | no |
| requester | 요청 VPC 정의. 기본 `aws` provider 의 계정·리전에 있는 VPC 다. 필드는 [requester 필드](#requester-필드) 참조 | <pre>object({<br>  vpc_id                          = string<br>  allow_remote_vpc_dns_resolution = optional(bool, true)<br>  private_domain                  = optional(string)<br>  routes = optional(map(object({<br>    route_table_id         = optional(string)<br>    route_table_name       = optional(string)<br>    destination_cidr_block = string<br>  })), {})<br>})</pre> | n/a | yes |
| accepter | 수락 VPC 정의. `aws.accepter` provider 의 계정·리전에 있는 VPC 다. `account_id`, `region` 은 생략하면 그 provider 에서 파생하고, 적으면 provider 실제 값과 일치해야 한다. 필드는 [accepter 필드](#accepter-필드) 참조 | <pre>object({<br>  account_id                      = optional(string)<br>  region                          = optional(string)<br>  vpc_id                          = string<br>  allow_remote_vpc_dns_resolution = optional(bool, true)<br>  private_domain                  = optional(string)<br>  routes = optional(map(object({<br>    route_table_id         = optional(string)<br>    route_table_name       = optional(string)<br>    destination_cidr_block = string<br>  })), {})<br>})</pre> | n/a | yes |
| tags | 양쪽 모든 리소스에 `context.tags` 뒤에 추가하는 태그. `Name` 은 보호 키이며 포함하면 plan 이 실패한다 | `map(string)` | `{}` | no |

### requester 필드

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | :---: |
| vpc_id | 요청 VPC ID | `string` | n/a | yes |
| allow_remote_vpc_dns_resolution | 요청 측 DNS 해석 옵션. 수락 VPC 리소스의 퍼블릭 DNS 호스트 이름을 프라이빗 IP 로 해석한다 | `bool` | `true` | no |
| private_domain | 요청 계정이 소유한 Private Hosted Zone 이름. 지정하면 그 존을 수락 VPC 에 연결한다 | `string` | `null` | no |
| routes | 요청 Route Table 에 추가할 경로. 키는 호출자가 정한 이름이며 리소스 키가 된다. `destination_cidr_block` 은 수락 VPC CIDR. 항목 필드는 [routes 항목 필드](#routes-항목-필드) 참조 | `map(object)` | `{}` | no |

### accepter 필드

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | :---: |
| account_id | 수락 VPC 를 소유한 12자리 AWS 계정 ID. 생략하면 `aws.accepter` provider 의 `sts:GetCallerIdentity` 결과에서 파생한다. 적은 값이 provider 실제 계정과 다르면 plan 이 실패한다 | `string` | `null` | no |
| region | 수락 VPC 리전. 생략하면 `aws.accepter` provider 의 리전에서 파생한다. 적은 값이 provider 리전과 다르면 plan 이 실패한다 | `string` | `null` | no |
| vpc_id | 수락 VPC ID | `string` | n/a | yes |
| allow_remote_vpc_dns_resolution | 수락 측 DNS 해석 옵션. 요청 VPC 리소스의 퍼블릭 DNS 호스트 이름을 프라이빗 IP 로 해석한다 | `bool` | `true` | no |
| private_domain | 수락 계정이 소유한 Private Hosted Zone 이름. 지정하면 그 존을 요청 VPC 에 연결한다 | `string` | `null` | no |
| routes | 수락 Route Table 에 추가할 경로. 키는 호출자가 정한 이름이며 리소스 키가 된다. `destination_cidr_block` 은 요청 VPC CIDR. 항목 필드는 [routes 항목 필드](#routes-항목-필드) 참조 | `map(object)` | `{}` | no |

### routes 항목 필드

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | :---: |
| route_table_id | 경로를 추가할 Route Table ID. `route_table_name` 과 둘 중 하나만 지정한다 | `string` | `null` | no |
| route_table_name | 경로를 추가할 Route Table 의 `Name` 태그. 같은 쪽 VPC 안에서 조회한다. `route_table_id` 와 둘 중 하나만 지정한다 | `string` | `null` | no |
| destination_cidr_block | 목적지 IPv4 CIDR. 상대 VPC 의 CIDR | `string` | n/a | yes |

## Outputs

| Name | Description |
| --- | --- |
| id | VPC Peering 연결 ID |
| name | Peering 연결의 `Name` 태그 값. `fullname` 을 적었으면 그 값, 생략했으면 `<name_prefix>-<name>-pcx` |
| accept_status | 수락 후 연결 상태 |
| requester_route_ids | `requester.routes` 키 → 요청 측에 생성한 경로 ID |
| accepter_route_ids | `accepter.routes` 키 → 수락 측에 생성한 경로 ID |
| requester_private_zone_id | 수락 VPC 에 연결한 요청 측 Hosted Zone ID. `requester.private_domain` 미설정이면 `null` |
| accepter_private_zone_id | 요청 VPC 에 연결한 수락 측 Hosted Zone ID. `accepter.private_domain` 미설정이면 `null` |
| accepter_account_id | 실제로 사용된 수락 계정 ID. `accepter.account_id` 를 적었으면 그 값, 생략했으면 `aws.accepter` provider 에서 파생한 값 |
| accepter_region | 실제로 사용된 수락 리전. `accepter.region` 을 적었으면 그 값, 생략했으면 `aws.accepter` provider 에서 파생한 값 |

## Authors

[oniops](https://github.com/oniops) 에서 관리합니다. 이슈와 변경 제안은 [저장소](https://github.com/oniops/tfmodule-aws-vpc-peer)에 남겨 주세요.

## License

MIT Licensed. 전문은 [LICENSE](./LICENSE) 를 참조하세요.
