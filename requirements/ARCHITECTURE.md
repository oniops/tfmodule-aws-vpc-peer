# tfmodule-aws-vpc-peer 아키텍처

이 문서는 `tfmodule-aws-vpc-peer` 모듈이 **왜 지금의 형태로 설계되었는지**를 다룬다. 아키텍처 개요, 모듈 경계, Hub & Spoke 구성 패턴, 구(kylo pcx) 구현과의 대조 분석, 네이밍·태그 정책의 설계 근거, 보안·비용 기본값의 설계 근거, 그리고 확정된 설계 결정(DECISIONS)을 기록한다.

이 문서의 정책은 시니어 모듈 정책 스페셜리스트가 확정한 설계 결정이며, 실제 구현(리소스 코드, `locals`, `validation`/`precondition` 구현, 테스트, README 생성)은 `terraform-aws-module-engineer` 가 담당한다.

- **"무엇을 충족해야 하는가"**(입력·출력 계약, 변수 구조 개선안, 검증 배치표, 버전 정책, Definition of Done)는 [REQUIREMENTS.md](REQUIREMENTS.md) 를 참조한다.
- **"어떻게 쓰는가"**(빠른 시작, 실제 호출 예시, Hub & Spoke 코드 샘플)는 [README.md](../README.md) 를 참조한다.

분석 대상:

- 현재 코드: `main.tf`, `routes.tf`, `route53-zone.tf`, `outputs.tf`, `variables.tf`, `variables-context.tf`, `versions.tf`, `README.md`, `target/demo/*`
- 구 참조 구현: `kylo/aws-services/vpc/pcx/`(이하 "kylo pcx")

---

## 1. 아키텍처 개요

### 1.1 모듈이 다루는 리소스 범위

모듈 인스턴스 하나가 두 VPC 사이의 Peering 연결 **하나**를 담당한다. 요청(requester) VPC 는 기본 `aws` provider, 수락(accepter) VPC 는 `aws.accepter` provider(`configuration_aliases`)로 다룬다.

| 리소스 | provider | 역할 |
| --- | --- | --- |
| `aws_vpc_peering_connection.this` | `aws` | Peering 요청 |
| `aws_vpc_peering_connection_accepter.this` | `aws.accepter` | 자동 수락(`auto_accept = true`). 이후 리소스는 이 리소스의 ID 를 참조해 `active` 상태를 기다린다 |
| `aws_vpc_peering_connection_options.requester` | `aws` | 요청 측 DNS 해석 옵션 |
| `aws_vpc_peering_connection_options.accepter` | `aws.accepter` | 수락 측 DNS 해석 옵션 |
| `aws_route.requester` (for_each) | `aws` | 요청 Route Table → 수락 VPC CIDR 경로 |
| `aws_route.accepter` (for_each) | `aws.accepter` | 수락 Route Table → 요청 VPC CIDR 경로 |
| `aws_route53_vpc_association_authorization` / `aws_route53_zone_association` (조건부, 양방향 독립) | 양쪽 | `private_domain` 을 지정한 쪽의 Private Hosted Zone 을 상대 VPC 에 연결 |
| `data.aws_route_table` (조건부, for_each) | 양쪽 | `route_table_name` 지정 시 `Name` 태그로 Route Table 조회 |
| `data.aws_route53_zone` (조건부) | 양쪽 | `private_domain` 지정 시 존 조회 |

모듈은 VPC, Route Table, 수락 계정의 IAM 역할을 **만들지 않는다**. 이 리소스들은 호출자 또는 다른 스택(예: `tfmodule-aws-vpc`, IAM 프로비저닝 스택)의 책임이다.

### 1.2 모듈 경계 (Convention over Configuration 관점)

| 항목 | 결정 | 근거 |
| --- | --- | --- |
| `provider`/`backend` 블록 | 모듈에 두지 않는다. `aws`, `aws.accepter` 두 provider 는 호출자가 `providers = {}` 로 주입 | 모듈 경계 정책. 리전 배치는 호출자 provider 가 정한다 |
| 인증 정보(assume_role 등) | 모듈이 갖지 않는다. 수락 계정 Assume Role 은 호출자가 provider 블록에서 구성 | 모듈에 인증 정보를 두지 않는다 |
| 수락 계정 IAM 역할 자체(신뢰정책, 권한정책) | 모듈 범위 밖. 이 모듈은 필요한 액션 목록만 문서화하고 리소스로 만들지 않는다 | "모듈이 소유하지 않는 리소스의 정책은 그 리소스를 소유한 스택의 책임" |
| 환경 구분 입력(`environment`, `stage` 등) | 두지 않는다. 호출자가 모듈을 여러 번 호출하는 것으로 환경 차이를 표현 | Environment-Specific Logic 안티패턴 회피 |
| 양쪽 VPC 자체 | 만들지 않는다. `vpc_id` 를 입력으로만 받는다 | README 의 명시적 원칙과 일치 |
| Peering 하나당 모듈 한 번 호출(`count`/`for_each` 없음) | 유지. 여러 Peering 은 호출자가 모듈을 여러 번 호출(`for_each` 가능)하거나 `count` 로 조건부 생성 | VPC Peering 은 전이 라우팅을 지원하지 않으므로 모듈 내부에서 "N개의 Peering" 을 한 번에 다루는 것은 모듈 책임 범위를 벗어난다. 호출자가 Hub & Spoke 반복을 스스로 구성하는 것이 옳다(→ §2, DECISION D-008) |

### 1.3 tfmodule-context 의존성 개요

모듈은 [tfmodule-context](https://github.com/oniops/tfmodule-context) 의 출력 `context` 를 필수 입력으로 받는다. 이 모듈이 실제로 쓰는 필드는 세 개뿐이다.

| 필드 | 용도 |
| --- | --- |
| `name_prefix` | `Name` 태그 접두어(`<name_prefix>-<name>-pcx`) |
| `tags` | 태그 병합 1단계 |
| `region` | Route53 Private Hosted Zone 교차 연결 인가(`vpc_region`)에 사용하는 요청 VPC 리전 |

`variable "context"` 타입은 v1.3.6 출력의 **부분집합**이며, 위 세 필드만 필수로 받고 `project`/`environment`/`owner`/`team`/`cost_center`/`pri_domain` 등 나머지는 `optional()` 로 받아 호환을 유지한다(타입에 없는 출력 필드는 Terraform 이 변환 시 버린다).

참조 버전을 **v1.3.6 이상**으로 확정한 근거, 단일 소스화 방법, 강제 메커니즘은 설계 결정이 아니라 준수해야 할 계약이므로 [REQUIREMENTS.md §6](REQUIREMENTS.md#6-tfmodule-context-의존성-정책--v136-이상-필수) 에 정의한다.

---

## 2. Hub & Spoke 구성 패턴

VPC Peering 은 **전이 라우팅(transitive routing)을 지원하지 않는다**. A-B, B-C 가 연결되어도 A-C 는 통신하지 못한다. 따라서 공유 서비스를 두는 Hub VPC 가 여러 Spoke VPC 와 개별적으로 Peering 을 맺는 Hub & Spoke 구성이 조직 표준 패턴이 된다.

이 모듈은 "Peering 하나"만 책임지는 얇은 단위로 설계했다. Hub & Spoke 를 이루는 N 개의 Peering 을 모듈 하나가 반복 처리하도록 만들지 않고, 대신 호출자가 Spoke 수만큼 모듈을 반복 호출하게 한다.

```text
                        ┌──────────────────────────────┐
                        │           Hub VPC            │
                        └───────┬──────────────┬───────┘
            <name_prefix>-A-pcx │              │ <name_prefix>-B-pcx
                ┌───────────────▼───────┐    ┌───▼──────────────────────┐
                │ Spoke A               │    │ Spoke B                  │
                └───────────────────────┘    └──────────────────────────┘
```

설계 근거(DECISION D-008):

- Hub&Spoke 조합 로직(어떤 Spoke 를 몇 개 만들지, 어떤 조건에서 만들지)은 **모듈이 아니라 호출자 Root Configuration 의 책임**이다. 모듈이 `for_each` 로 여러 Peering 을 내부에서 다루기 시작하면, "대상 목록을 어떻게 구조화할지"라는 호출자 고유의 설계 결정을 모듈이 강제하게 되어 Role 계층 강제 안티패턴과 유사한 결합이 생긴다.
- kylo pcx 의 근본 문제는 "모듈 내부에 다중화 로직이 없어서"가 아니라 "모듈 자체가 없어서 파일을 복사했기 때문"이었다(§3 참조). 얇은 모듈 + 호출자 반복 구성으로 복붙 문제가 해결됨을 확인했으므로, 모듈 내부에 다중 Peering 관리 기능을 추가할 필요가 없다.
- 실제 Hub & Spoke 호출 코드(두 개 Spoke 를 `route_table_name`/`route_table_id` 방식으로 각각 연결하는 전체 예시)는 [README.md Usage](../README.md#usage) 에 둔다. 이 문서는 패턴의 설계 근거만 다룬다.

---

## 3. 구현 대조 분석 — kylo pcx(구) vs tfmodule-aws-vpc-peer(신)

kylo pcx 는 `pcx-<target>-vpc.tf` 파일 13개가 Hub VPC(`com-an2p-vpc`) 하나를 기준으로 각 Spoke 마다 복사·붙여넣기 된 구조였다. 대조 결과는 다음과 같다.

| 항목 | kylo pcx (구) | tfmodule-aws-vpc-peer (신) | 판정 |
| --- | --- | --- | --- |
| 재사용성 | 대상마다 파일 전체(피어링, 옵션, 라우트, 존 연결, provider)를 복사. 대상 추가 = 신규 `.tf`/`variable`/`provider` 작성 | 모듈 1회 호출로 대상 1개 표현. 대상 추가 = 호출자 쪽 `module` 블록 추가 | 해결됨 |
| 조건부 생성 방식 | 대상별 전용 `variable "create_pcx_<target>_vpc"` 를 12개 이상 선언(Variable Explosion) | 호출자의 `module` 블록에 `count` 사용. 모듈 자체에는 전용 스위치 변수가 없음 | 해결됨 |
| 복붙 버그 실증 | `pcx-dev-an2d-vpc.tf` 의 `aws_vpc_peering_connection.devAn2dVpc` 태그가 `Name = "finops com-an2p-vpc to dev-an2d-vpc"` — `finops-ew1p` 파일을 복사하며 문자열을 고치지 않은 실제 버그 | 모듈이 `<name_prefix>-<name>-pcx` 를 코드로 파생하므로 이런 수기 문자열 불일치가 구조적으로 불가능 | 해결됨 |
| Route 리소스 키 | `"${route_table_id}-${cidr}"` 로 파생. CIDR 값을 바꾸면 키가 바뀌어 불필요한 재생성 발생 | 호출자가 정한 `routes` 맵 키를 그대로 `for_each` 키로 사용. CIDR 을 바꿔도 같은 키면 in-place 갱신(`~`) | 해결됨(멱등성 정책 준수) |
| Route Table 지정 방식 | ID 고정. `Name` 태그 조회 없음 | `route_table_id` 또는 `route_table_name`(데이터소스 조회) 중 선택 | 개선됨(확장) |
| Private Hosted Zone 연결 방향 | Spoke 존 → Hub VPC 한 방향만 지원 | `requester.private_domain`, `accepter.private_domain` 양방향 독립 지원 | 개선됨(확장) |
| 입력 검증 | 전무. `variable "stages" { type = any }` 로 구조 보증 없음. 오탈자·형식 오류가 apply 단계까지 감지되지 않음 | `name`, `routes[*]`, `accepter.account_id`, `tags` 에 `validation` 적용 | 개선됨 |
| 태그 | 리소스마다 수기 `Name`, `Description` 하드코딩. `context.tags` 이외의 조직 공통 규칙 없음 | `context.tags` → `tags` → `{Name}` 병합. `Name` 보호 키 | 개선됨 |
| Route53 대상 계정 IAM 역할 | provider 블록에 `role_arn` 하드코딩(계정 ID 포함), 권한 정책은 코드 밖에서 별도 관리 | 동일하게 호출자 provider 책임이나, 필요한 액션 목록·템플릿(`templates/*.tftpl`)을 모듈 저장소가 참고 자료로 제공 | 유지 + 문서화 개선 |
| tfmodule-context 버전 | `v1.3.4` | 코드상 `v1.3.5` 참조 — **v1.3.6 이상으로 상향 확정**(REQUIREMENTS.md §6) | 정책화 완료, 코드 반영은 engineer 위임 |
| 계정 ID/리전 중복 입력 | `accepter.aws_account`/`aws_region` 을 `stages` 맵에 수기 입력하면서 `provider` 블록의 `assume_role.role_arn` 안에도 같은 계정 ID 를 하드코딩 — 사실상 같은 값을 두 곳에 적음 | 동일한 패턴이 `accepter.account_id`/`accepter.region` 변수로 남아 있음 — **개선안 확정**(REQUIREMENTS.md §4) | 정책화 완료, 코드 반영은 engineer 위임 |
| `context` null 방어 | 해당 없음(`context` 를 쓰지 않음) | `context.name_prefix`/`tags`/`region` 을 `null` 방어 없이 직접 참조 — **검증 추가 확정**(REQUIREMENTS.md §7 표 8~10) | 정책화 완료, 코드 반영은 engineer 위임 |

**결론**: kylo pcx 가 갖고 있던 가장 큰 문제(복붙 중복, 조건부 생성 스위치 폭발, 재생성 유발 키, 검증 부재)는 이미 모듈화로 해결되었다. 남은 개선 대상은 (1) `accepter.account_id`/`region` 의 중복 입력, (2) `context` 필드의 `null` 방어, (3) tfmodule-context 참조 버전의 v1.3.6+ 상향이며, 이는 [REQUIREMENTS.md](REQUIREMENTS.md) 에서 계약으로 확정한다.

---

## 4. 네이밍 정책

| 대상 | 규칙 | 산식/예시 |
| --- | --- | --- |
| Peering 연결 `Name` 태그 (기본) | `<name_prefix>-<name>-pcx` | `context.name_prefix = "fruithub-an2p"`, `name = "apple"` → `fruithub-an2p-apple-pcx` |
| Peering 연결 `Name` 태그 (`fullname` 지정 시) | `fullname` 값 그대로. 모듈이 접두어·접미어를 붙이지 않는다 | `fullname = "fruithub-an2p-to-apple-an2p-pcx"` → `fruithub-an2p-to-apple-an2p-pcx` |
| `fullname` 입력 제약 | 생략(`null`) 가능. 값이 있으면 `name` 과 같은 문자 규칙 | 정규식 `^[a-z0-9][a-z0-9-]*$`. 위반 시 `validation` 으로 plan 실패 |
| `name` 입력 제약 | 소문자·숫자로 시작, 소문자·숫자·하이픈만 허용 | 정규식 `^[a-z0-9][a-z0-9-]*$`. 위반 시 `validation` 으로 plan 실패 |
| `name` 의 유일성 범위 | 요청 VPC 안에서 Peering 마다 달라야 함(모듈이 검사하지 않음) | 같은 값을 쓰면 `Name` 태그가 충돌해 콘솔에서 식별 불가 — `description` 에 명시 |
| `routes` 맵 키 | 호출자가 정한 이름. `aws_route` `for_each` 키로 그대로 사용되며 리소스 주소를 구성 | `pri-a1`, `pub` 등. 예약 키 없음(단일 Peering 범위이므로 다른 그룹과 충돌 위험 없음) |
| `route_table_name` 조회값 | 같은 쪽 VPC 안에서 `Name` 태그가 정확히 일치해야 함(1개만 매치) | `fruithub-an2p-pri-a1-rt` |
| `private_domain` 조회값 | 자기 VPC 에 이미 연결된 Private Hosted Zone 의 정확한 이름 | `apple.internal` |
| 이름 접두어 출처 | 기본 산식의 접두어는 `context.name_prefix` 하나뿐이며 이를 **부분적으로** 덮어쓰는 입력은 두지 않는다. `fullname` 은 접두어를 바꾸는 입력이 아니라 `Name` 태그 **전체**를 대체하는 단일 탈출구다(DECISION D-009) | — |
| 길이 제약 | 모듈은 `Name` 태그 길이를 검사하지 않는다. `variable "context"` 의 `description` 에 "name_prefix 가 길면 Name 태그가 길어질 수 있다"는 사실을 명시한다 | — |

이 모듈은 여러 입력을 조합해 이름을 만들지 않는다. 이름 산식은 `<name_prefix>-<name>-pcx` 하나이고, 그 산식을 통째로 대체하는 탈출구가 `fullname` 하나다(부분 조합·조건부 접미어 같은 중간 형태는 두지 않는다). 표에 없는 예외는 만들지 않는다.

`fullname` 을 둔 이유(DECISION D-009): 기본 산식의 접두어는 요청(requester) 측 `context` 에서만 오므로 "어느 VPC → 어느 VPC" 라는 Peering 의 방향성을 이름으로 표현할 수 없다. 그 방향을 이름에 담으려면 수락 측 `name_prefix` 에 해당하는 정보를 모듈이 알아야 하는데, 수락 측은 `vpc_id` 와 provider 로만 주어지므로 모듈이 파생할 수 없다. 따라서 조합 규칙을 늘리는 대신 이름 전체를 호출자가 지정하는 단일 입력을 둔다. `fullname` 은 `Name` 태그에만 작용하며 리소스 주소·`for_each` 키·출력 키 산식에는 관여하지 않는다.

---

## 5. 태그 정책

### 5.1 병합 순서

조직 표준 태그 병합 순서는 아래와 같다. **`Name` 은 반드시 병합의 마지막 단계에 와야 한다.**

```text
tags = merge(context.tags, <호출자 커스텀 tags>, { Name = <이름> })
```

| 순서 | 출처 | 필수 여부 |
| --- | --- | --- |
| 1 | `context.tags` | 필수(`context` 의 일부) |
| 2 | 호출자 커스텀 `tags`(모듈 공통 `tags` 하나만 존재. 리소스 유형별 `tags` 입력 없음) | 선택. 기본 `{}` |
| 3 | 모듈 생성 태그 `Name` | 항상 마지막 |

**설계 근거**: `Name` 을 마지막에 병합하면 "병합 순서 자체가 구조적으로 `Name` 을 보호"한다. `validation` 하나에만 의존해 `tags` 의 `Name` 입력을 막는 것은 방어선이 단일하다는 점에서 구조적으로 취약하다. 현재 코드(`main.tf`)는 `merge(context.tags, {Name}, tags)` 순서로 `Name` 을 중간에 두고 있어 이 원칙을 위반한다. 이를 `merge(context.tags, tags, {Name})` 으로 교정하는 결정이 **DECISION D-004**(§8)이며, 구체적 HCL 과 SemVer 판정은 [REQUIREMENTS.md §4.1](REQUIREMENTS.md#41-null-방어-추가) 및 §5 를 참조한다.

### 5.2 보호 키와 태그 소유권

- 보호 키는 `Name` 하나다. 호출자 커스텀 `tags` 에 `Name` 이 포함되면 plan 이 실패해야 한다.
- `context.tags` 의 키는 보호 키가 아니다. 호출자 커스텀 `tags` 로 덮어쓸 수 있다.
- 모듈이 만드는 태그는 `Name` 하나뿐이다. 그 **값**은 기본 산식(`<name_prefix>-<name>-pcx`) 또는 `fullname`(지정 시) 에서 오며, 어느 쪽이든 병합의 마지막 단계에서 모듈이 넣는다는 점은 같다. `ManagedBy`, `Environment` 같은 조직 공통 키는 `context.tags` 로 들어오므로 모듈이 다시 만들지 않는다.
- `aws_route`, `aws_vpc_peering_connection_options`, Route53 인가·연결 리소스는 AWS 제공자 스펙상 태그를 지원하지 않는다. 이는 모듈의 한계가 아니라 AWS 리소스 자체의 제약이므로 정책 위반이 아니며, `description`/README 에 그 사실을 명시하는 것으로 충분하다.
- 리소스 유형별 태그 입력(`route_tags`, `zone_tags` 등)을 별도로 두지 않는다. 모듈 공통 `tags` 하나만 존재한다.

---

## 6. 보안 기본값 설계 근거

이 모듈은 Security Group, NACL 등 트래픽 필터링 리소스를 직접 만들지 않는다. 모듈의 보안 경계는 "어떤 CIDR 을 어느 Route Table 에 여는가"와 "어느 계정으로 Peering 을 요청/수락하는가"로 제한된다. 이 전제에서 끌 수 없는 보안 기본값을 다음과 같이 확정한다.

| # | 항목 | 기본값/정책 | Override 가능 여부 | 근거 |
| --- | --- | --- | --- | --- |
| 1 | `Name` 태그 보호 | `tags` 로 `Name` 덮어쓰기 금지 | 불가 | 이름 정책 일관성 |
| 2 | 이름 접두어 출처 | `context.name_prefix` 단일 출처 | 불가 | 조직 네이밍 표준 |
| 3 | Peering 연결 자동 수락 여부 | `auto_accept = true` 고정 | 불가(입력 없음) | 모듈 호출 자체가 이미 "이 Peering 을 만들겠다"는 명시적 선언이므로, 수락을 별도로 껐다 켰다 하는 옵션은 목적이 없고 오히려 `pending-acceptance` 상태로 방치되는 리소스를 만들 위험만 키운다. 자동 수락을 끄고 싶다면 애초에 모듈을 호출하지 않는 것(`count = 0`)이 올바른 방법이다 |
| 4 | Route 생성 대상 | `routes` 에 선언한 항목만 생성(기본 `{}` = 0개) | — | "선언해야만 생성" 원칙 |
| 5 | Private Hosted Zone 교차 연결 | `private_domain` 을 지정한 쪽만, 지정한 방향만 생성(기본 `null` = 미생성) | — | 파생 생성 최소화 |

**`allow_remote_vpc_dns_resolution`(기본값 `true`, 양쪽 모두 override 가능)을 끌 수 없는 보안 기본값 목록에 포함하지 않는 이유(DECISION D-005)**: 이 옵션은 이미 Peering 으로 라우팅이 열린 두 VPC 사이의 "퍼블릭 DNS 호스트 이름 → 프라이빗 IP" 해석 여부만 바꾸며, 새로운 네트워크 도달 가능성이나 인가되지 않은 접근 경로를 열지 않는다. 따라서 Security by Default 가 아니라 Convention over Configuration 대상으로 분류하고, 조직 편의 기본값(`true`)을 두되 호출자가 필요 시 끌 수 있게 유지한다.

**`routes[*].destination_cidr_block` 을 좁은 범위로 강제하지 않는 이유**: 상대 VPC 의 실제 CIDR 이어야 하는 것이 Peering 의 본질이므로, 모듈이 이를 더 좁은 범위로 강제하는 것은 기능 자체를 무력화한다. 대신 `description` 에 "이 CIDR 로의 라우팅이 열리면 상대 VPC 전체 대역과 통신 가능해지며, 실제 접근 통제는 상대 VPC 의 Security Group/NACL 이 담당한다"는 사실을 명시한다.

---

## 7. 비용 정책 설계 근거

| 항목 | 정책 |
| --- | --- |
| Peering 연결 자체 | AWS 는 Peering 연결에 시간 단위 과금을 부과하지 않는다(과금은 Peering 을 경유하는 데이터 전송량 기준). 모듈 호출 자체가 곧 "선언"이므로 별도의 게이트 입력을 두지 않는다 |
| Route53 Private Hosted Zone 연결 | 존 자체(호스팅 비용)는 모듈이 만들지 않는다(존 소유 스택의 책임). 모듈은 기존 존을 상대 VPC 에 연결(Association)만 하며, Association 자체에 AWS 과금은 없다 |
| Cross-Region/Cross-AZ 데이터 전송 비용 | `routes` 로 열리는 경로를 통해 흐르는 트래픽이 리전 간 전송 요금을 유발할 수 있다. plan 에는 드러나지 않는 비용이므로 `requester.routes`/`accepter.routes` 의 `description` 에 그 사실을 명시한다 |
| 기존 리소스 재사용 | Route Table, Private Hosted Zone 은 모두 기존 리소스를 식별자(ID/이름)로 참조하는 구조이며 모듈이 신규로 만들지 않는다 |

---

## 8. DECISIONS (설계 결정 기록)

| ID | 결정 | 근거 | 영향 |
| --- | --- | --- | --- |
| D-001 | tfmodule-context 참조 버전을 `v1.3.6` 이상으로 상향하고, [REQUIREMENTS.md §6](REQUIREMENTS.md#6-tfmodule-context-의존성-정책--v136-이상-필수) 을 버전 문자열의 단일 소스로 지정 | README(`v1.3.5`)와 `target/demo`(`v1.3.4`)가 이미 서로 다른 값을 참조하는 드리프트가 발견됨. 과업 요구사항이 v1.3.6 이상을 명시적으로 요구 | README, `variables-context.tf`, `target/demo`, 향후 `examples/` 모두 동일 버전 표기로 일괄 교정 필요(engineer 위임) |
| D-002 | `accepter.account_id`, `accepter.region` 을 필수 → 선택(`optional`) + provider 파생 기본값으로 전환 | 동일 정보(계정 ID·리전)를 provider 블록과 변수 양쪽에 입력해야 하는 구조적 중복이 발견됨(kylo pcx 에서도 동일 패턴이 유지보수 비용의 원인이었음, §3). Convention over Configuration 원칙상 provider 로부터 파생 가능한 값은 입력을 강요하지 않아야 함 | `main.tf`에 `data.aws_caller_identity.accepter`, `data.aws_region.accepter` 추가, `outputs.tf`에 파생 값 출력 2개 추가. SemVer: MINOR |
| D-003 | D-002 의 파생 값 검증을 `precondition`이 아닌 `postcondition`으로 데이터 소스 자신에 배치 | 비교 대상(`self.account_id`, `self.region`)이 데이터 조회 이후에만 존재하므로 조회 이전에 평가되는 `precondition`으로는 표현 불가. Terraform 1.5 부터 데이터 소스에도 `lifecycle.postcondition` 사용 가능 | `required_version` 하한 유지(1.5.7) |
| D-004 | 태그 병합 순서를 `merge(context.tags, {Name}, tags)` → `merge(context.tags, tags, {Name})` 로 교정 | 조직 표준 태그 정책은 `Name`이 병합의 마지막 단계여야 구조적으로 보호됨을 요구. 현재 코드는 `validation` 하나에만 의존하는 단일 방어선이었음(§5.1) | 정상 입력의 결과값은 불변(이미 `tags`에 `Name`을 금지하는 검증이 있었으므로). SemVer: PATCH |
| D-005 | `allow_remote_vpc_dns_resolution`(기본 `true`, override 가능)을 "끌 수 없는 보안 기본값" 목록에서 제외 | 이 옵션은 이미 라우팅이 열린 두 VPC 사이의 DNS 이름 해석 범위만 바꾸며 새로운 네트워크 도달 가능성을 만들지 않음. Security by Default 가 아니라 Convention over Configuration(조직 편의 기본값) 영역으로 분류(§6) | 입력 변수 변경 없음(현행 `optional(bool, true)` 유지) |
| D-006 | `context.name_prefix`/`tags`/`region` 에 대한 `null` 방어 `validation` 3건 신규 추가 | 상위 조직 정책의 "필수 필드라도 값이 null일 수 있다. 그 값을 실제로 쓰는 시점에 null이면 plan 단계에서 실패시킨다"를 현재 코드가 지키지 않고 있음(문자열 보간 시 조용히 무시되거나 apply 단계에서만 실패) | `variables-context.tf` 수정. SemVer: PATCH(정상 입력 영향 없음) |
| D-007 | tfmodule-context 버전 하한을 `variable "context"` 타입에 새 필수 필드를 추가하는 방식으로 구조적으로 강제하지 않기로 결정(조건부 보류) | 실제로 필요하지 않은 필드를 오직 버전 검증 목적으로 추가하면 "리소스에 연결되지 않는 입력 변수를 두지 않는다" 정책과 충돌. v1.3.6 CHANGELOG 상 이 모듈에 기능적으로 필요한 신규 필드가 확인되면 그때 별도 MINOR/MAJOR 결정으로 재검토 | 버전 강제는 문서(REQUIREMENTS.md §6.3)와 CI grep 가드(§6.4)로 수행. engineer 가 v1.3.6 스키마를 확인한 뒤 이 DECISION 을 갱신할 수 있음(그 경우 이 문서를 먼저 개정) |
| D-008 | 모듈은 여전히 Peering 하나당 1회 호출 구조를 유지하고, 모듈 내부에 `for_each`/`count` 기반 다중 Peering 관리를 도입하지 않음 | VPC Peering 은 전이 라우팅을 지원하지 않으므로 "여러 Peering 을 한 모듈에서 관리"는 모듈 책임을 벗어난 조합 로직(Hub & Spoke 구성)이 되어, 호출자 Root Configuration 이 담당해야 할 조합을 모듈이 떠안게 됨(§2) | kylo pcx 의 13개 파일 반복 문제는 "모듈 내부에 다중화 로직을 넣는 것"이 아니라 "모듈을 얇게 만들고 호출자가 반복하게 하는 것"으로 해결됨을 확인(§3). 현행 구조 유지, 변경 없음 |
| D-009 | `Name` 태그를 통째로 대체하는 선택 입력 `fullname` 을 추가. 생략(`null`)이 기본이며 그때는 기존 산식 `<name_prefix>-<name>-pcx` 를 그대로 쓴다. `name` 은 계속 필수로 유지 | 기본 산식은 요청 측 `context.name_prefix` 만 알기 때문에 "requester → accepter" 라는 연결 방향을 이름으로 표현할 수 없고, 수락 측 접두어는 모듈이 파생할 수 없다(§4). 접두어를 부분적으로 덮어쓰는 입력을 여러 개 두는 대신 이름 전체를 대체하는 탈출구 하나만 둔다 | `Name` 태그 외에는 아무 영향이 없다. `fullname` 은 리소스 주소·`for_each` 키·출력 키 산식에 쓰이지 않으므로 기존 상태에서 값을 새로 지정해도 태그 in-place 갱신(`~`)만 발생하고 재생성(`-/+`)은 0건이다(`tests/idempotency.tftest.hcl` 의 `set_fullname_plan`, `scripts/check-idempotency.sh` 로 확인). SemVer: MINOR |

신규 MAJOR 변경(입력 제거, 출력 제거/타입 변경, 리소스 키 산식 변경)은 이번 결정 세트에 없다. 각 결정의 구체적 HCL, 마이그레이션 영향, SemVer 판정 표는 [REQUIREMENTS.md](REQUIREMENTS.md) 에서 다룬다.
