// 랜딩 설정. 값을 채우는 법은 landing/README.md 참고.
// 비밀(API 키 등)은 넣지 않는다. 여기 값은 모두 브라우저에 공개된다.
window.LANDING_CONFIG = {
  // 외부 폼 서비스의 제출 주소(POST). 비어 있으면 사전예약 버튼이 "준비 중"으로 안내한다.
  FORM_URL: "",
  // 방문 집계 도구가 제공하는 <script> 코드 조각(문자열). 비어 있으면 집계하지 않는다.
  ANALYTICS_SNIPPET: "",
  // 사전예약 버튼 클릭 이벤트 이름. 방문 대비 사전예약 5% 판정에 쓴다.
  PREORDER_CLICK_EVENT: "preorder_click"
};
