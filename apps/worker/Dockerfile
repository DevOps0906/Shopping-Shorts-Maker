# syntax=docker/dockerfile:1
# 영상 워커 (ADR-0002): Python 3.15.2 + FFmpeg 9.0.2 LGPL 빌드
# - 배포판 apt ffmpeg는 libx264 포함 GPL 빌드라 쓰지 않고 소스에서 빌드한다.
# - --enable-gpl·--enable-nonfree 없음. H.264는 libopenh264(BSD-2).

ARG PYTHON_IMAGE=python:3.15.2-slim-trixie@sha256:65a65fc7b30b06cb6df4930fd4650697cb23f4c2698ab81fc87e4b031bc36928

############################ FFmpeg 빌드 ############################
FROM ${PYTHON_IMAGE} AS ffmpeg-build

ARG FFMPEG_VERSION=9.0.2
# https://ffmpeg.org/releases/ffmpeg-9.0.2.tar.xz (2026-11-12 내려받아 계산)
ARG FFMPEG_SHA256=8c3850283eb25fa026482078a04051e0be17347b09ef81a0849bec15a96e002e

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      build-essential ca-certificates curl nasm pkg-config xz-utils \
      libopenh264-dev libass-dev libfreetype-dev libfontconfig-dev libfribidi-dev libharfbuzz-dev \
 && rm -rf /var/lib/apt/lists/*

WORKDIR /src
RUN curl -fsSLo ffmpeg.tar.xz "https://ffmpeg.org/releases/ffmpeg-${FFMPEG_VERSION}.tar.xz" \
 && echo "${FFMPEG_SHA256}  ffmpeg.tar.xz" | sha256sum -c - \
 && tar -xJf ffmpeg.tar.xz --strip-components=1 \
 && rm ffmpeg.tar.xz

RUN ./configure \
      --prefix=/opt/ffmpeg \
      --disable-debug --disable-doc --disable-ffplay \
      --disable-static --enable-shared \
      --enable-libopenh264 \
      --enable-libass --enable-libfreetype --enable-libfontconfig --enable-libfribidi --enable-libharfbuzz \
      --extra-ldflags="-Wl,-rpath,/opt/ffmpeg/lib" \
 && make -j"$(nproc)" \
 && make install

# LGPL 빌드 확인: GPL·nonfree 플래그가 있으면 빌드 실패
RUN ! /opt/ffmpeg/bin/ffmpeg -hide_banner -buildconf | grep -E -- '--enable-(gpl|nonfree)'

############################ 실행 이미지 ############################
FROM ${PYTHON_IMAGE}

RUN apt-get update \
 && apt-get install -y --no-install-recommends \
      libopenh264-8 libass9 libfreetype6 libfontconfig1 libfribidi0 libharfbuzz0b fonts-noto-cjk \
 && rm -rf /var/lib/apt/lists/*

COPY --from=ffmpeg-build /opt/ffmpeg /opt/ffmpeg
ENV PATH="/opt/ffmpeg/bin:${PATH}" \
    PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1

RUN groupadd --system --gid 10001 worker \
 && useradd --system --uid 10001 --gid worker --home-dir /app --shell /usr/sbin/nologin worker

WORKDIR /app
COPY --chown=root:root worker ./worker

USER worker
CMD ["python", "-m", "worker"]
