# ADR-0004 셀프 호스팅 구성(Docker Compose)
- 상태: 제안 · 날짜: 2026-11-12 · 근거: `docs/planning.md#17-2`(D4·D6) · `#17-10`

## 맥락
개발·운영 모두 같은 Compose로 셀프 호스팅한다(D6). Queues·Vault가 셀프 호스팅 이미지에서 되는지 확인이 필요했다.

## 결정
- Supabase 공식 `docker/docker-compose.yml`(2026-11-12 master)을 기준으로 두고, 우리 서비스는 별도 override 파일로 붙인다: Next.js 웹 · FFmpeg 워커 · 리버스 프록시.
- 진입: **Caddy**(TLS 자동 갱신)만 443 공개. 뒤에 웹과 Supabase API 게이트웨이(서비스명 `api-gw`, **Envoy**)를 둔다.
- Studio: 공개 라우트 없음, `127.0.0.1` 바인딩 + SSH 터널로만 접속.
- 버전 고정: 모든 이미지를 `태그@sha256:digest`로 적는다. `latest` 금지. 올릴 때는 스테이징에서 마이그레이션 먼저(17-10).

## 보안·운영 조건
- 게이트웨이 외부 라우트에서 Studio(대시보드)·`/pg/`(postgres-meta) 경로를 제거한다(`volumes/api/envoy` 설정 수정본을 우리 저장소에 둠). 외부엔 `/auth`·`/rest`·`/realtime`·`/storage`만.
- base가 게시하는 포트(`api-gw` 8000·HTTPS 사용 시 8443, `supavisor` 5432·6543)를 override에서 `ports: !reset []`로 지운다. Docker가 iptables를 직접 고쳐 UFW를 우회하므로 방화벽만 믿지 않는다.
- 교체 필수 기본 비밀: `POSTGRES_PASSWORD` · `JWT_SECRET` · `ANON_KEY` · `SERVICE_ROLE_KEY` · `DASHBOARD_PASSWORD` · `SECRET_KEY_BASE` · `VAULT_ENC_KEY`(supavisor용) · `PG_META_CRYPTO_KEY` · `REALTIME_DB_ENC_KEY` · `LOGFLARE_*_ACCESS_TOKEN` · 새 비대칭 키(`JWT_KEYS`·`SUPABASE_SECRET_KEY` 등). 값은 서버 환경 파일에만.
- 확인 항목: Vault 루트 키는 `db-config` 볼륨(`/etc/postgresql-custom`)에 저장됨 → 이 볼륨을 DB 백업과 **분리해** 서버 밖에 보관하고, 컨테이너 재시작·백업 복구 후 `vault.decrypted_secrets` 복호화가 되는지 복구 리허설에서 실측한다.
- 완료 조건(배포 시): 외부에서 포트 스캔(`nmap -p- <서버>`) 결과가 443·SSH만 열림.

## 확인 결과 (2026-11-12, `supabase/postgres:17.6.1.136`, 임시 컨테이너·볼륨 없음)
digest `sha256:f371b5f3f2ac0a05703f33d6e6134515fb2498cab708fb948a0aeb7481467c00`
`select name, default_version from pg_available_extensions where name in ('pgmq','supabase_vault')`
→ `pgmq 1.5.1`(미설치, 사용 가능) · `supabase_vault 0.3.1`(기본 설치됨). 추가로 `create extension pgmq` 후 `pgmq.create/send/read` 실측 통과.

## 대안
Supabase Cloud·Railway(D6에서 거부) · nginx + certbot(구성 요소가 늘어 차선) · Traefik(MIT, 라벨 기반, 차선).

## 결과
+ 개발=운영, 외부 의존 최소. − 업그레이드·백업·보안 패치를 직접 운영. 공식 compose 변경(예: Kong→Envoy)을 업그레이드 때마다 비교해야 함.

## 버전·라이선스
supabase/postgres 17.6.1.136 · studio 2026.11.02-sha-a05e7ec · gotrue v2.197.0 · postgrest v14.18 · realtime v2.148.3 · storage-api v1.89.12 · Envoy v1.39.6(compose 고정, 최신 stable 1.40.2 — 공식 compose가 올릴 때 따라감) · Caddy v2.11.9 — 모두 Apache-2.0/MIT/PostgreSQL 계열(GPL·AGPL 없음, `secscan license`로 재확인).
