"""렌더 입력 내려받기·결과 업로드 위치 검사(팀장 결정: 워커는 Storage 키가 없다).

웹 서버가 job 생성 때 짧은 서명 URL을 payload 에 넣는다.
- 내려받기: payload.source_urls{source_id: url}(sources 버킷) · payload.voice_url(voices 버킷)
- 올리기: payload.upload_url(renders 버킷 서명 업로드 URL) · payload.upload_expires_at
payload 는 사용자가 create_job RPC로 직접 넣을 수도 있으므로:
- 내려받기 경로는 /storage/v1/object/sign/<bucket>/<DB에 기록된 객체 경로> 와 정확히 같아야 한다(다른 객체 요청 차단).
- 접속지(origin)는 payload 값을 쓰지 않고 WORKER_STORAGE_URL(내부망 게이트웨이)로 바꾸고, 리다이렉트는 따라가지 않는다.
URL·토큰은 로그·오류 문구에 넣지 않는다.
"""

from __future__ import annotations

import os
import re
import time
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from ..voice.storage import UploadTarget

SIGN_PREFIX = "/storage/v1/object/sign/"
UPLOAD_PREFIX = "/storage/v1/object/upload/sign/renders/"
RENDER_OBJECT_RE = re.compile(r"^[0-9a-f-]{36}/[0-9a-f-]{36}/[A-Za-z0-9._-]{1,120}\.mp4$")
CHUNK = 1 << 20


class FetchError(Exception):
    """내려받기·위치 오류. transient 면 다시 시도할 만한 오류. 메시지는 사용자 문구."""

    def __init__(self, message: str, transient: bool) -> None:
        super().__init__(message)
        self.transient = transient


MSG_BAD_LINK = "원본·음성 파일 링크가 올바르지 않습니다. 화면을 새로 고친 뒤 다시 만들어 주세요."
MSG_EXPIRED = "파일 링크 기한이 지났습니다. 다시 만들어 주세요."
MSG_DOWN = "파일을 받지 못해 잠시 뒤 다시 시도합니다."
MSG_TOO_BIG = "파일이 너무 큽니다."
MSG_TIMEOUT = "파일 내려받기 시간이 작업 제한을 넘었습니다."


def _origin(base: str | None) -> str:
    origin = (base if base is not None else os.environ.get("WORKER_STORAGE_URL", "")).rstrip("/")
    if not origin.startswith(("http://", "https://")):
        raise FetchError(MSG_BAD_LINK, transient=False)
    return origin


def _token(parts: urllib.parse.SplitResult) -> str:
    tokens = urllib.parse.parse_qs(parts.query).get("token", [])
    if len(tokens) != 1 or not tokens[0]:
        raise FetchError(MSG_BAD_LINK, transient=False)
    return tokens[0]


def download_url(raw: Any, bucket: str, object_path: str, base: str | None = None) -> str:
    """payload 의 서명 다운로드 URL이 DB 객체 경로를 가리킬 때만, 접속지를 바꾼 URL을 돌려준다."""
    if not isinstance(raw, str) or not object_path or ".." in object_path:
        raise FetchError(MSG_BAD_LINK, transient=False)
    parts = urllib.parse.urlsplit(raw)
    prefix = f"{SIGN_PREFIX}{bucket}/"
    if not parts.path.startswith(prefix) or urllib.parse.unquote(parts.path[len(prefix):]) != object_path:
        raise FetchError(MSG_BAD_LINK, transient=False)
    token = _token(parts)
    return f"{_origin(base)}{prefix}{urllib.parse.quote(object_path)}?{urllib.parse.urlencode({'token': token})}"


def upload_target(payload: dict[str, Any], user_id: str, project_id: str, now: datetime | None = None,
                  base: str | None = None) -> UploadTarget:
    raw, expires = payload.get("upload_url"), payload.get("upload_expires_at")
    if not isinstance(raw, str) or not isinstance(expires, str):
        raise FetchError(MSG_BAD_LINK, transient=False)
    try:
        deadline = datetime.fromisoformat(expires.replace("Z", "+00:00"))
    except ValueError:
        raise FetchError(MSG_BAD_LINK, transient=False) from None
    if deadline.tzinfo is None:
        raise FetchError(MSG_BAD_LINK, transient=False)
    if (now or datetime.now(timezone.utc)) >= deadline:
        raise FetchError(MSG_EXPIRED, transient=False)
    parts = urllib.parse.urlsplit(raw)
    if not parts.path.startswith(UPLOAD_PREFIX):
        raise FetchError(MSG_BAD_LINK, transient=False)
    object_path = urllib.parse.unquote(parts.path[len(UPLOAD_PREFIX):])
    if (not RENDER_OBJECT_RE.match(object_path) or ".." in object_path
            or not object_path.startswith(f"{user_id}/{project_id}/")):
        raise FetchError(MSG_BAD_LINK, transient=False)
    token = _token(parts)
    url = f"{_origin(base)}{UPLOAD_PREFIX}{urllib.parse.quote(object_path)}?{urllib.parse.urlencode({'token': token})}"
    return UploadTarget(url, object_path)


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, *args: Any, **kwargs: Any) -> None:  # 리다이렉트로 다른 주소에 가지 않는다
        return None


_OPENER = urllib.request.build_opener(_NoRedirect)


def download(url: str, dest: Path, max_bytes: int, timeout: float, deadline: float | None = None,
             check: Callable[[], None] | None = None) -> int:
    """스트리밍으로 dest 에 쓴다(상한 초과 시 중단). 반환: 바이트 수.

    deadline(time.monotonic 기준 절대 마감, 보통 작업 마감)을 넘기면 일시 오류가 아니라 실패(MSG_TIMEOUT)다.
    느린 서버가 조금씩 보내 소켓 시간 초과를 피하는 경우도 청크마다 남은 시간·취소(check)를 검사해 끊는다.
    """
    def left() -> float:
        if check is not None:
            check()  # 취소·작업 시간 초과면 Stopped
        if deadline is None:
            return timeout
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise FetchError(MSG_TIMEOUT, transient=False)
        return min(timeout, remaining)

    try:
        with _OPENER.open(urllib.request.Request(url, method="GET"), timeout=left()) as r:
            if r.status != 200:
                raise FetchError(MSG_EXPIRED, transient=False)
            size = 0
            with open(dest, "wb") as f:
                while True:
                    left()
                    chunk = r.read1(CHUNK)  # 도착한 만큼만(read 는 CHUNK 를 다 채울 때까지 막힘)
                    if not chunk:
                        break
                    size += len(chunk)
                    if size > max_bytes:
                        raise FetchError(MSG_TOO_BIG, transient=False)
                    f.write(chunk)
            left()
            return size
    except urllib.error.HTTPError as e:
        if e.code >= 500 or e.code == 429:
            raise FetchError(MSG_DOWN, transient=True) from None
        raise FetchError(MSG_EXPIRED, transient=False) from None  # 400·403·404·3xx: 만료·위조·삭제
    except (TimeoutError, urllib.error.URLError, ConnectionError):
        if deadline is not None and time.monotonic() >= deadline:
            raise FetchError(MSG_TIMEOUT, transient=False) from None
        raise FetchError(MSG_DOWN, transient=True) from None
