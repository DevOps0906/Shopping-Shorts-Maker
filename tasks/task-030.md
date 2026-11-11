# task-030 Docker Compose 개발 스택(Supabase 셀프 호스팅·웹·워커)

| 항목 | 내용 |
|---|---|
| 웨이브 | W2 |
| 선행 | task-005 |
| 위험도 | 높음 |
| 보안 영향 | 의존성(Supabase·FFmpeg 이미지), 노출 면(Kong·Studio·DB 포트), 키·권한(JWT secret·anon·service_role) |
| 담당 | builder (착수 전 challenger) |
| 근거 | `docs/adr/0004-*.md`, `docs/planning.md#17-2`(D4·D6), `docs/planning.md#17-10`, `AGENTS.md#2` |
| 쓰기 허용 | `docker/**`, `docker-compose*.yml`, `apps/web/Dockerfile`, `apps/worker/Dockerfile`, `.env.example`, `.dockerignore` |

## 할 것
- Supabase 공식 셀프 호스팅 compose(Postgres·Auth·Storage·Realtime·REST·Kong) 도입, 이미지 태그를 ADR 0004대로 고정
- Studio는 내부망(로컬 바인딩)만, Postgres 포트 외부 미노출
- 웹(Next.js)·FFmpeg 워커 컨테이너 Dockerfile과 compose 서비스 추가
- 비밀은 `.env`(커밋 금지)로만, `.env.example`에는 키 이름만

## 하지 않을 것
- 리버스 프록시·TLS·운영 서버 설정(task-031)
- 앱 코드·마이그레이션 작성(task-009~012)

## 완료 조건 (실행 가능한 확인)
- [ ] `docker compose config -q` 통과, `docker compose up -d` 후 전 서비스 healthy
- [ ] `psql`에서 `pgmq`·`supabase_vault` 확장 생성 성공
- [ ] `docker compose ps`에서 5432·Studio 포트가 `127.0.0.1` 바인딩만
- [ ] `secscan` 비밀 0건, `.env` git 미추적
