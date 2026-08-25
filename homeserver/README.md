# Song Yuna portfolio Mac mini runbook

이 디렉터리는 Mac mini 운영 파일의 **secret 없는 source copy**다. 현재 bundle을
GitHub에 push하는 것만으로 운영 파일이 설치되지는 않는다. 아래 단계는 모두
별도의 운영·credential·첫 배포 승인을 받은 뒤 live 상태, backup, rollback을
재확인하고 수행한다.

## 고정 mapping

```text
homeserver/compose.yaml
  -> /Users/homeserver/Server/apps/songyuna-portfolio/compose.yaml

homeserver/scripts/deploy-songyuna-portfolio-ci.sh
  -> /Users/homeserver/Server/scripts/deploy/deploy-songyuna-portfolio-ci.sh
```

runtime state는 Git에 넣지 않는다.

```text
/Users/homeserver/Server/apps/songyuna-portfolio/image.env
/Users/homeserver/Server/apps/songyuna-portfolio/deployment.state
/Users/homeserver/Server/apps/songyuna-portfolio/deployment.pending
/Users/homeserver/Server/apps/songyuna-portfolio/deployment.lock
```

`image.env`에는 `SONGYUNA_PORTFOLIO_IMAGE=ghcr.io/lalayuna/portfolio@sha256:...`
한 줄만 저장한다. registry token, SSH key, Tailscale credential, tunnel token은
어떤 runtime file에도 저장하지 않는다.

## 배포 계약

GitHub Actions가 보내는 SSH original command는 다음 한 형식만 허용한다.

```text
deploy-songyuna-portfolio <sha256:image-digest> <40-char-commit-sha> <registry-user>
```

stable bootstrap은 다음을 강제한다.

- image repository를 `ghcr.io/lalayuna/portfolio`로 고정
- digest, lowercase commit SHA와 registry user 형식 검증
- GHCR token을 argument·environment·log에 넣지 않고 stdin으로만 수신
- temporary Docker config를 mode `0700` directory에 만들고 종료 시 제거
- pulled image의 OCI source와 revision label 검증
- `lockf`로 deploy/recover 직렬화
- candidate exact digest를 `--pull never --no-build`로 실행
- container health, 내부 `/health`와 `/` 확인
- 성공 뒤에만 verified `deployment.state` atomic 갱신
- 실패 시 previous exact local digest로 rollback
- first deploy 실패 시 새 Compose project만 내리고 public DNS를 만들지 않음

## 운영 bootstrap preflight

변경 전 다음을 읽기 전용으로 확인한다.

1. exact target path, 기존 파일·symlink·mode와 동일 이름 container 부재
2. Memory Pressure, disk, Docker 상태와 기존 운영 service health
3. 외부 Docker network `edge` 존재와 새 service의 host port/bind/socket 부재
4. `/usr/local/bin/docker`, Docker Compose plugin, `/usr/bin/lockf` 실행 가능
5. 설치 대상 파일별 timestamp backup과 정확한 원복 경로
6. Tailscale `tag:ci`가 허용된 Mac mini SSH target만 접근하는지
7. Cloudflare route와 public DNS가 아직 비활성인지

Compose와 bootstrap은 개별 backup 후 atomic install하고 각각 mode `0644`, `0700`을
적용한다. `/Users/homeserver/.ssh/authorized_keys`에는 기존 줄을 보존한 채 songyuna
전용 public key 한 줄만 추가한다. private key는 Mac mini, repository, 문서,
메신저에 복사하지 않는다.

authorized key option의 형태는 다음과 같다. 실제 public key와 comment는 운영
승인 중 별도 생성·확인한다.

```text
restrict,command="/Users/homeserver/Server/scripts/deploy/deploy-songyuna-portfolio-ci.sh" ssh-ed25519 <CI_PUBLIC_KEY> songyuna-portfolio-ci
```

## GitHub와 Tailscale 설정

Tailscale federated identity는 GitHub OIDC issuer와 다음 claim을 가능한 한 좁게
일치시킨다.

- repository: `LalaYuna/Portfolio`
- ref: `refs/heads/main`
- workflow: `.github/workflows/delivery.yml`
- tag: `tag:ci`

GitHub `Production` environment에는 `TS_OAUTH_CLIENT_ID`, `TS_AUDIENCE`,
`HOME_MINI_SSH_KEY`, `HOME_MINI_KNOWN_HOSTS`를 owner가 직접 입력한다. repository
variables `HOME_MINI_HOST`, `HOME_MINI_SSH_USER`를 설정하되
`MAC_MINI_DEPLOY_ENABLED`는 bootstrap preflight 완료 전까지 missing 또는 `false`로
유지한다.

## 첫 배포 preflight

운영 변경 승인 뒤 다음을 검증한다.

```bash
/Users/homeserver/Server/scripts/deploy/deploy-songyuna-portfolio-ci.sh \
  --validate-forced-command \
  "deploy-songyuna-portfolio sha256:<64-lowercase-hex> <40-lowercase-hex> <registry-user>"
```

실제 값은 source나 문서에 저장하지 않는다. 임의 command, path, uppercase/잘못된
digest·SHA, extra argument가 exit `64`로 거부되는지 확인한다. mock 또는 격리된
preflight에서 lock 경합, candidate health 실패, previous rollback, previous가 없는
first-deploy failure를 검증하기 전에는 gate를 활성화하지 않는다.

## 실패와 복구

- validation 실패: image publish와 Mac mini 접근 없이 현재 container 유지
- publish 성공·SSH 이전 실패: 새 immutable image만 GHCR에 남고 현재 container 유지
- pull/label 검증 실패: Compose와 state를 바꾸지 않고 중단
- candidate 실패·rollback 성공: 이전 verified image 유지, workflow 실패
- candidate와 rollback 모두 실패: `deployment.pending` 보존, 자동 재배포 중단
- first deploy 실패: 새 project만 중단, DNS 비활성 유지

중단된 transaction은 pending/state/env를 직접 편집하거나 삭제하지 않고 별도 운영
승인 아래 stable bootstrap의 direct recovery를 실행한다.

```bash
/Users/homeserver/Server/scripts/deploy/deploy-songyuna-portfolio-ci.sh recover
```

recovery는 verified state의 exact local image만 `--pull never`로 복구한다. verified
state가 없는 first-deploy recovery는 새 project를 내리고 `image.env`와 pending만
정리한다. 다른 Compose project, image, volume, `edge` network는 삭제하지 않는다.

## 공개 전 완료 조건

1. GitHub exact head와 required workflow 성공
2. GHCR digest와 OCI revision/source label 일치
3. `songyuna-portfolio` container healthy, 내부 root/asset/404 확인
4. 기존 운영 container와 public URL 회귀 없음
5. rollback 또는 first-deploy failure 경로 성공
6. 별도 DNS 승인 후 Cloudflare route, authoritative nameserver, TLS 확인
7. `https://songyuna.co.kr`, 대표 asset, desktop/mobile 실제 browser smoke 확인
