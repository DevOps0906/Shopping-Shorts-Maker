"""voices 버킷 업로드(팀장 결정: 워커는 Storage 키가 없다).

웹 서버가 job 생성 때 서명 업로드 URL(payload.upload_url)과 기한(payload.upload_expires_at, 10분)을 넣고,
워커는 그 URL로만 PUT 한다. URL·토큰은 로그·오류 문구에 넣지 않는다.

payload 는 사용자가 create_job RPC로 직접 넣을 수도 있으므로:
- 경로는 /storage/v1/object/upload/sign/voices/<user>/<project>/<파일> 형태만 받는다(객체 경로 소유 범위는 save_voice_take 가 다시 검사).
- 접속지(origin)는 payload 값을 쓰지 않고 워커 환경 변수 WORKER_STORAGE_URL(내부망 게이트웨이)로 바꾼다(임의 주소 요청 방지).
"""

from __future__ import annotations

import os
import re
import urllib.error
import urllib.parse
import urllib.request
from datetime import datetime, timezone
from typing import Any

from .providers import ProviderError

SIGN_PREFIX = "/storage/v1/object/upload/sign/voices/"
OBJECT_RE = re.compile(r"^[0-9a-f-]{36}/[0-9a-f-]{36}/[A-Za-z0-9._-]{1,120}$")

MSG_BAD_TARGET = "음성 저장 위치가 올바르지 않습니다. 다시 생성해 주세요."
MSG_EXPIRED = "음성 저장 기한이 지났습니다. 다시 생성해 주세요."
MSG_UPLOAD_DOWN = "음성 파일을 저장하지 못해 잠시 뒤 다시 시도합니다."


class UploadTarget:
    def __init__(self, url: str, object_path: str) -> None:
        self.url = url
        self.object_path = object_path

    def __repr__(self) -> str:  # 서명 URL을 실수로 출력하지 않게
        return f"UploadTarget(object_path={self.object_path!r})"


def parse_target(payload: dict[str, Any], now: datetime | None = None, base: str | None = None) -> UploadTarget:
    raw = payload.get("upload_url")
    expires = payload.get("upload_expires_at")
    if not isinstance(raw, str) or not isinstance(expires, str):
        raise ProviderError(MSG_BAD_TARGET, transient=False)
    try:
        deadline = datetime.fromisoformat(expires.replace("Z", "+00:00"))
    except ValueError:
        raise ProviderError(MSG_BAD_TARGET, transient=False) from None
    if deadline.tzinfo is None:
        raise ProviderError(MSG_BAD_TARGET, transient=False)
    if (now or datetime.now(timezone.utc)) >= deadline:
        raise ProviderError(MSG_EXPIRED, transient=False)

    parts = urllib.parse.urlsplit(raw)
    query = urllib.parse.parse_qs(parts.query)
    tokens = query.get("token", [])
    if not parts.path.startswith(SIGN_PREFIX) or len(tokens) != 1 or not tokens[0]:
        raise ProviderError(MSG_BAD_TARGET, transient=False)
    object_path = urllib.parse.unquote(parts.path[len(SIGN_PREFIX):])
    if not OBJECT_RE.match(object_path) or ".." in object_path:
        raise ProviderError(MSG_BAD_TARGET, transient=False)

    origin = (base if base is not None else os.environ.get("WORKER_STORAGE_URL", "")).rstrip("/")
    if not origin.startswith(("http://", "https://")):
        raise ProviderError(MSG_BAD_TARGET, transient=False)
    url = f"{origin}{SIGN_PREFIX}{urllib.parse.quote(object_path)}?{urllib.parse.urlencode({'token': tokens[0]})}"
    return UploadTarget(url, object_path)


def upload(target: UploadTarget, data: bytes, content_type: str, timeout: float) -> None:
    req = urllib.request.Request(target.url, data=data, method="PUT",
                                 headers={"Content-Type": content_type, "x-upsert": "true"})
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            r.read()
    except urllib.error.HTTPError as e:
        if e.code >= 500 or e.code == 429:
            raise ProviderError(MSG_UPLOAD_DOWN, transient=True) from None
        # 400·403: 토큰 만료·위조·형식 거부. 같은 URL로 다시 해도 실패한다
        raise ProviderError(MSG_EXPIRED, transient=False) from None
    except (TimeoutError, urllib.error.URLError):
        raise ProviderError(MSG_UPLOAD_DOWN, transient=True) from None
