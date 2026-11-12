# ADR-0002 영상 워커 컨테이너 언어: Python + FFmpeg(LGPL 빌드)
- 상태: 제안 · 날짜: 2026-11-12 · 근거: `docs/planning.md#17-2`(D4) · `#7` · `AGENTS.md#2`

## 맥락
워커는 큐를 소비해 컷·9:16 크롭·이어 붙이기·자막·음성 합성을 FFmpeg로 처리한다. PoC(`poc/agency/run.py`)는 Python 3.11+ 표준 라이브러리 + ffmpeg 8.1 하위 프로세스로 15·20초 영상을 만들었고, 인코딩은 libx264 `crf 23 veryfast`(GPL)다. 입력은 타인이 올린 영상이라 신뢰할 수 없다.

## 결정
- 언어: **Python 3.15**(이미지 `python:3.15-slim`, 태그·digest 고정). PoC의 구조(컷 맵→필터 그래프)는 참고하되 인코더·샌드박스는 아래 조건으로 다시 짠다.
- DB·큐: psycopg 3로 Postgres 직접 접속(내부망), `pgmq` 함수 호출(ADR-0001). FFmpeg는 링크하지 않고 하위 프로세스로만 실행.
- FFmpeg: **9.0 LGPL 빌드**(`--enable-gpl`·`--enable-nonfree` 없음). 배포판 apt `ffmpeg`는 libx264 포함 GPL 빌드라 쓰지 않는다.
- H.264 인코딩: libx264 대신 libopenh264(BSD-2) 또는 하드웨어 인코더.

## 보안·운영 조건
- 입력 파싱: `-protocol_whitelist file`(HLS·concat 재생목록으로 외부 URL·로컬 파일 읽기 차단), 입력 포맷 강제(`-f`로 mp4·mov·webm 화이트리스트, 먼저 ffprobe로 판별·불일치면 거부).
- 프로세스 분리: DB·Storage에 접속하는 조정 프로세스와 ffmpeg/ffprobe 실행 프로세스를 나눈다. ffmpeg는 **네트워크 없는(`network_mode: none` 또는 별도 netns) 비root 샌드박스**에서 작업 디렉터리만 읽기·쓰기.
- 자원 상한: ffmpeg 프로세스당 CPU·메모리 제한(cgroup/compose `cpus`·`mem_limit`), 벽시계 시간 상한(렌더 10분, 17-5) 초과 시 강제 종료.
- **승인 전 측정 항목(openh264 합격 기준)**: libx264 crf23 대비 VMAF ≥ 93(가설), 같은 화질에서 비트레이트 증가 ≤ 30%, 15초 영상 렌더 시간 ≤ 60초(운영 서버 기준). 불합격 시 대안 = 하드웨어 인코더(NVENC/QSV/VAAPI) → 그래도 불합격이면 사용자 결정 항목으로 올린다.
- **사용자 결정 대기**: "서버 내부에서만 쓰는(배포하지 않는) GPL 도구 libx264에도 GPL 거부 규칙을 적용하는가?" 현재안 = 적용(LGPL 빌드). 적용 안 함으로 결정되면 libx264로 바꾼다.

## 대안
| 대안 | 판단 |
|---|---|
| Node.js/TypeScript (웹과 언어 통일) | 타입 공유 이점. 큐는 pg-boss로 대체 가능. 차선 |
| Go (단일 바이너리) | 이미지 작음. 재작성 비용 대비 이득 작음 |
| GPL 빌드 + libx264 | 화질 최상이나 GPL 거부 규칙(AGENTS.md#4) 위반 — 위 사용자 결정에 따름 |

## 결과
+ PoC 구조 재사용, 음성·이미지 분석 라이브러리 생태계. − 웹(TS)과 타입 이중 관리 → DB 생성 타입에서 Python 모델을 만드는 단계 필요. − openh264 측정 전까지 화질 위험 남음.

## 버전·라이선스
Python 3.15.2(PSF) · FFmpeg 9.0.2 "Lei"(LGPL-2.1+ 빌드만) · psycopg 3.3.8(LGPL-3.0, 라이브러리 사용 허용) · OpenH264(BSD-2).
