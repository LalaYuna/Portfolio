# Song Yuna Portfolio delivery bundle

이 폴더는 `LalaYuna/Portfolio`에 전달할 **Git 없는 source bundle**이다.
Mac mini의 기존 Git 계정이나 여자친구의 GitHub credential을 사용하지 않는다.
여자친구가 자신의 컴퓨터에서 내용을 확인하고 직접 `main`에 commit·push한다.

`public/` 화면은 여자친구가 수정한 결과다. 전달용 배포 파일만 갱신할 때는
`public/`을 기존 GitHub repository에 다시 복사하거나 덮어쓰지 않는다. 공개 전에는
소개·프로젝트·연락처가 실제 공개 가능한 사실인지 최종 확인한다.

## 폴더 구조

```text
public/                         실제로 공개되는 HTML/CSS/JS와 asset
.github/workflows/delivery.yml main 검증, 조건부 image 발행과 배포
Dockerfile                     ARM64 non-root Nginx image
nginx.conf                     정적 파일, /health, 보안 header
scripts/                       dependency 없는 source/배포 계약 검증
tests/                         Git context, forced-command와 배포 transaction 검증
homeserver/                    운영 파일의 secret 없는 source copy와 runbook
```

Docker image에는 `public/`만 복사된다. `README`, workflow, homeserver script,
secret 이름 같은 배포 자료는 웹에서 제공되지 않는다.

## 콘텐츠 수정 위치

가장 먼저 다음 항목을 수정한다.

1. `public/index.html`
   - 소개 문구와 희망 직무
   - 실제 프로젝트명, 역할, 과정, 결과
   - 실제 공개가 허용된 연락처와 social link
2. `public/assets/styles.css`
   - 색상은 파일 상단 `:root` 변수에서 조정
3. `public/assets/`
   - image를 추가한 뒤 `index.html`에서 `/assets/...` 절대 경로로 참조
4. `public/sitemap.xml`
   - page가 늘어날 때 공개 URL 추가

현재 contact form은 의도적으로 없다. 이메일 전송, 개인정보 수집, analytics,
backend가 필요하면 정적 배포 범위를 넘어가므로 별도 설계와 승인을 거친다.

## 전달 무결성 확인

전달 시 폴더 바깥에 다음 세 파일이 함께 제공된다.

```text
songyuna-portfolio-delivery.SHA256SUMS
songyuna-portfolio-delivery.zip
songyuna-portfolio-delivery.zip.sha256
```

ZIP checksum을 먼저 확인한 뒤 압축을 푼다. Finder에서 보이지 않을 수 있는
`.github`, `.gitignore`, `.dockerignore`도 포함됐는지 확인한다. 외부 checksum
파일 자체는 GitHub repository에 넣지 않는다.

## GitHub 반영

첫 반영은 여자친구 컴퓨터에서 이 bundle의 **내용 전체**를 repository root에
복사한다. 이후 전달용 배포 파일만 갱신할 때는 안내받은 파일만 교체하고 기존
`public/`은 보존한다. commit·push는 여자친구의 Git identity와 credential로
`main`에서 수행한다. Mac mini와 이 전달 폴더에서는 clone, commit, remote 연결,
push를 하지 않는다.

운영 담당자가 SSH key와 연결 preflight 완료를 알리기 전에는 push하지 않는다.
그 전까지 GitHub repository variable `MAC_MINI_DEPLOY_ENABLED`는 만들지 않거나
정확히 `false`로 둔다. 준비가 끝나 gate를 `true`로 바꾸면 첫 `main` push부터
검증, GHCR publish와 Mac mini deploy를 연속 실행한다.

## 검증

HTML link, filename case, 접근성 기본 구조와 secret-like file만 빠르게 확인한다.

```bash
bash ./scripts/verify-static-site.sh
```

Docker CLI와 Ruby가 있는 환경에서는 Compose, workflow pin/gate, forced-command
거부 계약까지 확인한다.

```bash
bash ./scripts/verify-delivery.sh
```

전달 폴더는 계속 Git 없이 보관한다. 검증기는 `.git`을 기본 거부하며,
`GITHUB_ACTIONS=true`이고 `GITHUB_WORKSPACE`가 검증 대상 root와 정확히 일치하는
GitHub Actions checkout에서만 실제 `.git` directory를 허용한다.

Mac mini에서는 production image를 build하지 않는다. `linux/arm64` image build,
non-root runtime, `/health`, root/asset/404와 security header 검증은 GitHub-hosted
ARM64 runner가 수행한다.

## 자동 배포 준비값

운영 bootstrap을 별도 승인으로 완료한 뒤 repository owner가 GitHub에 직접
설정한다. password, PAT, private key 원문을 문서나 대화에 붙여 넣지 않는다.

Repository variable:

| 이름 | 역할 |
| --- | --- |
| `MAC_MINI_DEPLOY_ENABLED` | 정확히 `true`일 때만 publish/deploy 활성화 |

`Production` environment variables:

| 이름 | 역할 |
| --- | --- |
| `HOME_MINI_HOST` | Tailscale에서 접근할 Mac mini hostname |
| `HOME_MINI_SSH_USER` | forced-command key를 둔 제한된 SSH user |

`Production` environment secrets:

| 이름 | 역할 |
| --- | --- |
| `TS_OAUTH_CLIENT_ID` | repository/workflow claim으로 제한한 Tailscale federated identity client ID |
| `TS_AUDIENCE` | 위 federated identity audience |
| `HOME_MINI_SSH_KEY` | songyuna 배포 전용 CI private key |
| `HOME_MINI_KNOWN_HOSTS` | 사전에 확인한 Mac mini SSH host key entry |

`GITHUB_TOKEN`은 GitHub Actions가 job별로 발급한다. 별도 PAT를 만들지 않는다.

## 배포 활성화 순서

1. 운영 담당자가 Mac mini Compose와 forced-command bootstrap 설치
2. Tailscale WIF, SSH public key와 GitHub variable/secret 설정
3. 잘못된 command/digest/SHA, lock, first-deploy failure와 rollback preflight
4. Cloudflare/Gabia DNS 위임과 apex Tunnel route 확인
5. SSH/Tailscale 연결 확인 뒤 `MAC_MINI_DEPLOY_ENABLED=true` 설정
6. 여자친구의 첫 `main` push로 검증, image publish와 첫 배포
7. container 내부와 `https://songyuna.co.kr` 공개 응답 검증

일상 운영에서는 여자친구의 `main` push가 같은 validation → immutable digest →
forced-command deployment 흐름을 실행한다. validation 실패나 deploy 실패는
기존 정상 container를 자동으로 Git history까지 되돌리지는 않는다.

## 이 bundle이 하지 않은 일

- Git repository 생성, clone, commit, push
- GitHub variable/secret/environment 변경
- Mac mini `/Users/homeserver/Server` 파일 변경
- container build, pull, restart 또는 deploy
- Cloudflare Tunnel, zone, 가비아 nameserver 변경
