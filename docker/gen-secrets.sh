#!/bin/sh
#
# 루트 .env 생성: 공식 예시 비밀을 쓰지 않고 전부 무작위 값으로 만든다 (ADR-0004 교체 필수 목록).
# 비밀 생성은 Supabase 공식 utils/generate-keys.sh를 그대로 호출하고, 출력만 받아 .env를 쓴다.
#
# 사용:  sh docker/gen-secrets.sh           # .env가 없을 때만 생성
#        sh docker/gen-secrets.sh --force   # 기존 .env를 .env.bak.<시각>으로 옮기고 새로 생성
#                                            (DB가 이미 초기화됐다면 POSTGRES_PASSWORD가 달라져 접속 불가 — 볼륨도 새로 만들 때만)
# 요구: openssl
# 출력: 값은 화면에 찍지 않는다. .env는 .gitignore 대상이며 권한 600으로 만든다.

set -eu

root_dir=$(cd "$(dirname "$0")/.." && pwd)
env_file="$root_dir/.env"
keygen="$root_dir/docker/supabase/utils/generate-keys.sh"

force=false
[ "${1:-}" = "--force" ] && force=true
if [ -f "$env_file" ] && [ "$force" != "true" ]; then
    echo "이미 .env가 있습니다. 덮어쓰려면 --force (DB 볼륨도 새로 만들 때만)." >&2
    exit 1
fi

if ! command -v openssl >/dev/null 2>&1; then
    echo "openssl이 필요합니다." >&2
    exit 1
fi

# 1) 비밀을 전부 먼저 만든다. 공식 스크립트는 비대화형이면 키만 출력하고 .env를 건드리지 않는다.
keys=$(sh "$keygen" </dev/null)

secret_names="POSTGRES_PASSWORD JWT_SECRET ANON_KEY SERVICE_ROLE_KEY DASHBOARD_PASSWORD SECRET_KEY_BASE VAULT_ENC_KEY PG_META_CRYPTO_KEY REALTIME_DB_ENC_KEY LOGFLARE_PUBLIC_ACCESS_TOKEN LOGFLARE_PRIVATE_ACCESS_TOKEN S3_PROTOCOL_ACCESS_KEY_ID S3_PROTOCOL_ACCESS_KEY_SECRET"
for name in $secret_names; do
    v=$(printf '%s\n' "$keys" | grep "^$name=" | head -n 1 | cut -d= -f2-) || v=""
    if [ -z "$v" ]; then
        echo "생성 실패: $name (기존 .env는 그대로 둠)" >&2
        exit 1
    fi
    eval "s_$name=\$v"
done

# 2) 권한 600 임시 파일에 완성한 뒤, 성공했을 때만 기존 .env를 백업하고 교체한다.
umask 077
tmp_file=$(mktemp "$root_dir/.env.tmp.XXXXXX")
trap 'rm -f "$tmp_file"' EXIT INT TERM
cat > "$tmp_file" <<EOF
# 생성: docker/gen-secrets.sh ($(date +%Y-%m-%d)). git에 올리지 않는다. 키 이름 목록은 .env.example
# Windows에서도 경로 구분자 문제 없이 쓰도록 COMPOSE_FILE은 두지 않는다(루트 docker-compose.yml이 include).

############ 비밀 (무작위 생성) ############
POSTGRES_PASSWORD=${s_POSTGRES_PASSWORD}
JWT_SECRET=${s_JWT_SECRET}
ANON_KEY=${s_ANON_KEY}
SERVICE_ROLE_KEY=${s_SERVICE_ROLE_KEY}
DASHBOARD_PASSWORD=${s_DASHBOARD_PASSWORD}
SECRET_KEY_BASE=${s_SECRET_KEY_BASE}
VAULT_ENC_KEY=${s_VAULT_ENC_KEY}
PG_META_CRYPTO_KEY=${s_PG_META_CRYPTO_KEY}
REALTIME_DB_ENC_KEY=${s_REALTIME_DB_ENC_KEY}
LOGFLARE_PUBLIC_ACCESS_TOKEN=${s_LOGFLARE_PUBLIC_ACCESS_TOKEN}
LOGFLARE_PRIVATE_ACCESS_TOKEN=${s_LOGFLARE_PRIVATE_ACCESS_TOKEN}
S3_PROTOCOL_ACCESS_KEY_ID=${s_S3_PROTOCOL_ACCESS_KEY_ID}
S3_PROTOCOL_ACCESS_KEY_SECRET=${s_S3_PROTOCOL_ACCESS_KEY_SECRET}

# 새 비대칭 키(sb_ 키). 비워 두면 레거시 HS256 모드. 켜려면 docker/supabase/utils/add-new-auth-keys.sh 참고(팀장 결정 사항)
SUPABASE_PUBLISHABLE_KEY=
SUPABASE_SECRET_KEY=
ANON_KEY_ASYMMETRIC=
SERVICE_ROLE_KEY_ASYMMETRIC=
JWT_KEYS=
JWT_JWKS=

############ 설정 (비밀 아님) ############
DASHBOARD_USERNAME=supabase

POSTGRES_HOST=db
POSTGRES_DB=postgres
POSTGRES_PORT=5432
POOLER_PROXY_PORT_TRANSACTION=6543
POOLER_DEFAULT_POOL_SIZE=20
POOLER_MAX_CLIENT_CONN=100
POOLER_TENANT_ID=shopping-shorts
POOLER_DB_POOL_SIZE=5

# 호스트 루프백 포트 (pnpm dev가 3000을 쓰고, 이 PC의 다른 Supabase CLI 스택이 543xx~603xx를 써서 Studio는 8300)
API_GW_HTTP_PORT=8000
STUDIO_PORT=8300
WEB_PORT=3001

SUPABASE_PUBLIC_URL=http://localhost:8000
API_EXTERNAL_URL=http://localhost:8000
SITE_URL=http://localhost:3000
ADDITIONAL_REDIRECT_URLS=

# pgmq 스키마는 노출하지 않는다 (ADR-0001)
PGRST_DB_SCHEMAS=public,storage,graphql_public

JWT_EXPIRY=3600
DISABLE_SIGNUP=false
ENABLE_EMAIL_SIGNUP=true
ENABLE_EMAIL_AUTOCONFIRM=false
ENABLE_ANONYMOUS_USERS=false
ENABLE_PHONE_SIGNUP=false
ENABLE_PHONE_AUTOCONFIRM=false
MAILER_URLPATHS_CONFIRMATION=/auth/v1/verify
MAILER_URLPATHS_INVITE=/auth/v1/verify
MAILER_URLPATHS_RECOVERY=/auth/v1/verify
MAILER_URLPATHS_EMAIL_CHANGE=/auth/v1/verify

# 메일 발송은 아직 없음 (실제 SMTP는 운영 설정에서)
SMTP_ADMIN_EMAIL=admin@example.com
SMTP_HOST=supabase-mail
SMTP_PORT=2500
SMTP_USER=
SMTP_PASS=
SMTP_SENDER_NAME=Shopping Shorts

STUDIO_DEFAULT_ORGANIZATION=Shopping Shorts
STUDIO_DEFAULT_PROJECT=Shopping Shorts
OPENAI_API_KEY=

IMGPROXY_AUTO_WEBP=true
GLOBAL_S3_BUCKET=stub
REGION=stub
STORAGE_TENANT_ID=stub

FUNCTIONS_VERIFY_JWT=false

WORKER_CPUS=2
WORKER_MEM_LIMIT=2g
EOF

if [ -f "$env_file" ]; then
    backup="$env_file.bak.$(date +%Y%m%d%H%M%S)"
    mv "$env_file" "$backup"
    echo "기존 .env를 $(basename "$backup")로 옮겼습니다."
fi
mv "$tmp_file" "$env_file"
trap - EXIT INT TERM

echo ".env 생성 완료 ($(grep -c '=' "$env_file")개 항목, 값은 출력하지 않음)."
