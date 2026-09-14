# AWS VPC Peering Terraform module

두 VPC 사이의 VPC Peering 연결을 구성하는 Terraform 모듈입니다. 요청(requester) VPC 와 수락(accepter) VPC 가 서로 다른 AWS 계정·리전에 있어도 동작하며, Peering 요청·수락, DNS 해석 옵션, 양쪽 Route Table 경로, Route53 Private Hosted Zone 교차 연결을 한 번의 호출로 만듭니다.

모듈 인스턴스 하나가 Peering 연결 하나를 담당합니다. 요청 VPC 는 기본 `aws` provider, 수락 VPC 는 `aws.accepter` provider 로 다루며, 수락이 끝나 연결이 `active` 가 된 뒤 옵션·경로·존 연결을 만듭니다.

양쪽 VPC 는 이 모듈이 만들지 않습니다. VPC ID, Route Table, 상대 VPC CIDR 은 호출자가 값을 직접 적으며, Route Table 은 ID(`route_table_id`) 또는 `Name` 태그(`route_table_name`) 중 편한 쪽으로 지정합니다.

## Usage

모듈에는 `provider` 블록이 없습니다. 호출자가 `providers` 로 요청 VPC 의 `aws` 와 수락 VPC 의 `aws.accepter` 를 반드시 넘겨야 하며, `aws.accepter` 의 계정·리전은 `accepter.account_id`, `accepter.region` 과 같아야 합니다.

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
module "ctx" {
  source      = "git::https://github.com/oniops/tfmodule-context.git?ref=v1.3.5"
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

  # Spoke 측
  accepter = {
    account_id     = "222222222222"
    region         = "ap-northeast-2"
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

양쪽 Route Table 을 ID 로 직접 지정합니다. 리전이 다른 Spoke 이므로 `accepter.region` 과 `aws.banana` provider 의 리전을 `us-east-1` 로 맞춥니다. Private Hosted Zone 연결은 생략한 예시입니다.

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

  # Spoke 측
  accepter = {
    account_id = "333333333333"
    region     = "us-east-1"
    vpc_id     = "vpc-0ccccccccccccccc"
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
```

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

  # Spoke 측 cherry-vpc (10.103.0.0/16). 같은 계정이므로 account_id 는 Hub 계정의 ID 다.
  accepter = {
    account_id = module.ctx.account_id
    region     = module.ctx.region
    vpc_id     = "vpc-0ddddddddddddddd"
    routes     = { pri-a1 = { route_table_id = "rtb-0ddddddddddddddd1", destination_cidr_block = "10.100.0.0/16" } }
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
| 2 | 모듈 생성 태그 | `Name = <name_prefix>-<name>-pcx` |
| 3 | `tags` | 호출자 커스텀 태그 |

`Name` 은 보호 키입니다. `tags` 에 `Name` 을 넣으면 plan 이 실패합니다. `aws_route`, `aws_vpc_peering_connection_options`, Route53 인가·연결 리소스는 태그를 지원하지 않습니다.

## Notes

- VPC Peering 은 전이 라우팅을 지원하지 않습니다. A-B, B-C 가 연결되어도 A-C 는 통신하지 못하므로 필요한 쌍마다 모듈을 호출합니다.
- 두 VPC 의 CIDR 이 겹치면 AWS 가 요청을 거부합니다.
- `routes` 의 키가 `aws_route` 의 리소스 키가 됩니다. 항목을 추가·제거해도 다른 키의 경로에는 변경(`~`)이나 재생성(`-/+`)이 생기지 않습니다. 키 이름을 바꾸면 그 경로는 삭제 후 재생성됩니다.
- `name` 을 바꾸면 `Name` 태그만 갱신되며 Peering 연결은 재생성되지 않습니다. `requester.vpc_id`, `accepter.account_id`, `accepter.region`, `accepter.vpc_id` 를 바꾸면 Peering 연결과 그에 딸린 경로·존 연결이 재생성됩니다.
- 모든 `aws_route` 는 `timeouts` 의 `create`, `update`, `delete` 를 `5m` 으로 둡니다.
- 이미 다른 코드로 만든 Peering 을 이 모듈로 옮기면 리소스 주소가 바뀌어 재생성이 계획됩니다. `moved` 블록이나 `terraform state mv` 로 상태를 먼저 옮깁니다.
- 수락 측 Route Table 에 이미 같은 목적지 CIDR 경로가 있으면 `aws_route` 생성이 실패합니다. 기존 경로를 제거하거나 `terraform import` 로 가져옵니다.
- 아래 조건에 걸리면 plan 단계에서 실패합니다.

| 대상 | 조건 |
| --- | --- |
| `name` | `^[a-z0-9][a-z0-9-]*$` 에 맞지 않음 |
| `accepter.account_id` | 12자리 숫자가 아님 |
| `requester.routes[*]`, `accepter.routes[*]` | `route_table_id` 와 `route_table_name` 이 둘 다 없거나 둘 다 있음 |
| `requester.routes[*]`, `accepter.routes[*]` | `destination_cidr_block` 이 유효한 IPv4 CIDR 이 아님 |
| `tags` | `Name` 키 포함 |
| `route_table_name` | 같은 VPC 안에 `Name` 태그가 일치하는 Route Table 이 없거나 둘 이상 (data source 조회 실패) |
| `private_domain` | 자기 VPC 에 연결된 같은 이름의 Private Hosted Zone 이 없음 (data source 조회 실패) |

## Validation

Terraform 1.5.x 에서는 `configuration_aliases` 를 가진 모듈을 루트에서 단독으로 `terraform validate` 할 수 없습니다. 두 provider 를 넘기는 호출 스택을 임시로 만들어 검증합니다.

```hcl
provider "aws" {
  region = "ap-northeast-2"
}

provider "aws" {
  alias  = "accepter"
  region = "us-east-1"
}

module "vpc_peer" {
  source    = "<모듈 경로>"
  providers = { aws = aws, aws.accepter = aws.accepter }

  context   = { name_prefix = "sample-an2p", tags = {}, region = "ap-northeast-2" }
  name      = "sample"
  requester = { vpc_id = "vpc-0123456789abcdef0" }
  accepter  = { account_id = "111122223333", region = "us-east-1", vpc_id = "vpc-0123456789abcdef1" }
}
```

```shell
terraform init -backend=false
terraform validate
```

## Requirements

| Name | Version |
| --- | --- |
| terraform | >= 1.5.7 |
| aws | >= 6.0, < 7.0 |

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
| [aws_route_table.requester](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route_table) | data source |
| [aws_route_table.accepter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route_table) | data source |
| [aws_route53_zone.requester](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |
| [aws_route53_zone.accepter](https://registry.terraform.io/providers/hashicorp/aws/latest/docs/data-sources/route53_zone) | data source |

`requester` 접미어 리소스는 `aws`, `accepter` 접미어 리소스는 `aws.accepter` provider 로 만듭니다. 단, `aws_route53_zone_association.requester` 는 요청 측 존을 수락 VPC 에 연결하므로 `aws.accepter` 로, `aws_route53_zone_association.accepter` 는 `aws` 로 만듭니다.

## Inputs

| Name | Description | Type | Default | Required |
| --- | --- | --- | --- | :---: |
| context | tfmodule-context 출력 객체. `name_prefix`(Name 태그 접두어), `tags`(태그 병합 1단계), `region`(요청 VPC 리전)만 쓰고 나머지 필드는 무시한다. `module.ctx.context` 를 그대로 넘긴다 | <pre>object({<br>  name_prefix  = string<br>  tags         = map(string)<br>  region       = string<br>  region_alias = optional(string)<br>  project      = optional(string)<br>  environment  = optional(string)<br>  env_alias    = optional(string)<br>  owner        = optional(string)<br>  team         = optional(string)<br>  cost_center  = optional(number)<br>  pri_domain   = optional(string)<br>})</pre> | n/a | yes |
| name | Peering 키. `Name` 태그 `<name_prefix>-<name>-pcx` 의 `<name>`. 요청 VPC 안에서 Peering 마다 달라야 하며 소문자·숫자로 시작하고 소문자·숫자·하이픈만 허용한다 | `string` | n/a | yes |
| requester | 요청 VPC 정의. 기본 `aws` provider 의 계정·리전에 있는 VPC 다. 필드는 [requester 필드](#requester-필드) 참조 | <pre>object({<br>  vpc_id                          = string<br>  allow_remote_vpc_dns_resolution = optional(bool, true)<br>  private_domain                  = optional(string)<br>  routes = optional(map(object({<br>    route_table_id         = optional(string)<br>    route_table_name       = optional(string)<br>    destination_cidr_block = string<br>  })), {})<br>})</pre> | n/a | yes |
| accepter | 수락 VPC 정의. `aws.accepter` provider 의 계정·리전에 있는 VPC 이며 `account_id`, `region` 은 그 provider 와 같아야 한다. 필드는 [accepter 필드](#accepter-필드) 참조 | <pre>object({<br>  account_id                      = string<br>  region                          = string<br>  vpc_id                          = string<br>  allow_remote_vpc_dns_resolution = optional(bool, true)<br>  private_domain                  = optional(string)<br>  routes = optional(map(object({<br>    route_table_id         = optional(string)<br>    route_table_name       = optional(string)<br>    destination_cidr_block = string<br>  })), {})<br>})</pre> | n/a | yes |
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
| account_id | 수락 VPC 를 소유한 12자리 AWS 계정 ID | `string` | n/a | yes |
| region | 수락 VPC 리전 | `string` | n/a | yes |
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
| name | Peering 연결의 `Name` 태그 값 `<name_prefix>-<name>-pcx` |
| accept_status | 수락 후 연결 상태 |
| requester_route_ids | `requester.routes` 키 → 요청 측에 생성한 경로 ID |
| accepter_route_ids | `accepter.routes` 키 → 수락 측에 생성한 경로 ID |
| requester_private_zone_id | 수락 VPC 에 연결한 요청 측 Hosted Zone ID. `requester.private_domain` 미설정이면 `null` |
| accepter_private_zone_id | 요청 VPC 에 연결한 수락 측 Hosted Zone ID. `accepter.private_domain` 미설정이면 `null` |

## Authors

[oniops](https://github.com/oniops) 에서 관리합니다. 이슈와 변경 제안은 [저장소](https://github.com/oniops/tfmodule-aws-vpc-peer)에 남겨 주세요.

## License

MIT Licensed. 전문은 [LICENSE](./LICENSE) 를 참조하세요.
