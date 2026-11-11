# 랜딩·사전예약 페이지 (task-001)

정적 HTML 1장(`index.html` + `styles.css` + `config.js`), 의존성·빌드 없음. 브라우저로 `index.html`을 열거나 아무 정적 호스팅에 폴더째 올리면 됩니다.

## config.js 채우는 법
1. 외부 폼 서비스(POST로 제출을 받는 서비스)에서 폼을 만들고 필드 이름을 `email`·`channels`·`product`·`consent`로 맞춥니다.
2. 그 서비스의 제출 주소를 `FORM_URL`에 넣습니다. 비워 두면 버튼이 "사전예약 준비 중"으로 안내만 합니다. 연락처는 이 저장소·서버에 저장하지 않습니다.
3. 방문 집계 도구가 주는 `<script>` 코드 조각을 문자열 그대로 `ANALYTICS_SNIPPET`에 넣습니다(비밀 키는 넣지 않습니다. 이 파일은 공개됩니다).
4. `PREORDER_CLICK_EVENT`(기본 `preorder_click`)는 사전예약 버튼 클릭 때 `gtag`·`plausible`·`dataLayer`로 보내는 이벤트 이름입니다. 집계 도구에서 같은 이름으로 목표를 만듭니다.
5. 판정: 사전예약 수(폼 서비스의 제출 수) ÷ 방문 수(집계 도구) ≥ 5%면 통과(`docs/00_LEAN.md`). 클릭 수는 이탈 확인용 보조 지표입니다.
