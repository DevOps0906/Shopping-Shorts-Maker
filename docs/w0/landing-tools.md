# 랜딩 외부 도구 비교 (task-001: 폼 · 방문 집계)

> 확인일 2026-11-12, 각 서비스 공식 페이지 기준(아래 출처). 한도·가격은 바뀔 수 있으니 가입 직전 다시 확인한다.
> 전제(`landing/README.md`): 정적 HTML이 `<form method="post" action=FORM_URL>`로 제출(AJAX 아님), 필드 `email`·`channels`·`product`·`consent`, 연락처는 외부 서비스에만 저장. 클릭 이벤트는 `index.html`의 `track()`이 `gtag`·`plausible`·`dataLayer`로만 보낸다.

## 1. 폼 서비스
| 후보 | 무료 한도 | 정적 HTML action POST | 데이터 지역 · 개인정보 | 가입 난이도 | 비고 |
|---|---|---|---|---|---|
| Formspree | 월 50건, 폼 무제한 | 지원(엔드포인트 URL을 action에 그대로) | 미국 등 운영 국가로 이전(처리방침), 제출 보관 기간 명시 없음 | 쉬움(이메일 가입 → 폼 생성) | 무료는 완료 후 Formspree 기본 감사 페이지(맞춤 리디렉트 유료, $15/월~) |
| Tally | 폼·제출 무제한(공정 사용) | **미지원**: 자체 폼 화면 임베드·링크 방식. 우리 HTML 폼을 버리고 Tally 폼으로 교체해야 함 | EU(벨기에) 저장, GDPR 명시 | 쉬움 | 랜딩 디자인과 폼 화면이 분리됨 |
| Google Forms | 무제한 | **공식 미지원**: `formResponse` 주소로 POST는 비공식 우회, 필드명이 `entry.123…`라 우리 필드명과 안 맞음, 응답 확인 불가 | Google 계정 · 미국 등 | 쉬움 | 구조 변경 시 깨질 수 있어 비권장 |
| Web3Forms | 공식 페이지 403으로 미확인 | 지원(access_key 숨은 필드) | 미확인 | 쉬움 | 확인 못 해 후보에서 제외 |

## 2. 방문 집계
| 후보 | 무료 한도 | 쿠키 · 배너 | 이벤트(목표) | 데이터 지역 | 가입 난이도 | 비고 |
|---|---|---|---|---|---|---|
| Umami Cloud (Hobby) | 무료, 월 이벤트 10만, 사이트 1, 보관 6개월 | 쿠키 없음(배너 불필요라고 명시) | 지원(`umami.track`) | 미국·EU 서버 | 쉬움 | `track()`가 umami를 안 부름 → 3절의 연결 한 줄 필요 |
| Plausible | 무료 없음, 30일 체험 후 $9/월(월 1만 페이지뷰) | 쿠키 없음 | 지원(Goals · custom events) | EU 호스팅 | 쉬움(카드 불필요 체험) | `track()`이 그대로 동작. 검증이 30일 넘으면 유료 |
| Cloudflare Web Analytics | 무료, 한도 언급 없음 | 쿠키·localStorage 미사용 | **미지원**(FAQ "Not yet") | Cloudflare | 쉬움(JS 비콘, 프록시 불필요) | 방문 수만 가능, 클릭 보조 지표 불가. 조회 시 샘플링 있음 |
| GA4 | 무료(웹 이벤트 이름 무제한, 보관 최대 14개월) | `_ga`·`_ga_<ID>` 쿠키 2년 → 동의 배너 검토 필요 | 지원(`gtag`, 핵심 이벤트 30개) | Google | 보통(속성·데이터 스트림 설정) | `track()` 그대로 동작. 배너 추가는 랜딩 수정 필요 |

## 3. 추천: Formspree(무료) + Umami Cloud(Hobby)
- 이유: 둘 다 무료이고 지금 HTML을 바꾸지 않고 `config.js` 값만으로 동작한다. Formspree는 우리 폼에 action POST를 그대로 받는 유일한 확인된 후보, Umami는 무료 중 쿠키 없이 이벤트까지 집계되는 유일한 후보다.
- 제약: Formspree 월 50건 → 판정 5% 기준이면 방문 약 1,000/월까지 충분. 넘으면 유료 전환 또는 Plausible·Tally 재검토. 제출 후 Formspree 기본 페이지로 이동한다.
- 클릭 이벤트 연결: `index.html`의 `track()`이 `umami.track`을 직접 부르므로(2026-11-12 반영) Umami 추적 코드만 넣으면 됩니다.
- 대안: 검증 기간이 30일 이내면 Formspree + Plausible 체험(연결 코드 불필요).

## 4. 사용자 가입 절차 (5단계)
1. formspree.io 가입 → New Form 생성 → 받은 `https://formspree.io/f/<폼ID>`를 복사, 알림 이메일 확인.
2. Formspree 폼 설정에서 허용 도메인을 랜딩 도메인으로 제한(있으면) 하고 테스트 제출 1건 확인.
3. cloud.umami.is 가입(Hobby) → Add website에 랜딩 도메인 입력 → Tracking code 복사.
4. 아래 형태로 `landing/config.js`에 붙여 넣는다(비밀 키 없음, 공개 값만).
5. Umami 대시보드 Events에 `preorder_click`이 보이는지, Formspree 제출 수가 늘어나는지 확인 → 판정 = Formspree 제출 수 ÷ Umami 방문자 수.

## 5. config.js 값 형태 (예시, 실제 값 아님)
```js
FORM_URL: "https://formspree.io/f/xxxxxxxx",
ANALYTICS_SNIPPET: '<script defer src="https://cloud.umami.is/script.js" data-website-id="00000000-0000-0000-0000-000000000000"></script>',
PREORDER_CLICK_EVENT: "preorder_click"
```

## 6. 개인정보 (검토 필요)
- 이메일이 Formspree(미국)·Umami(미국/EU)에 저장·처리된다. 개인정보보호법상 처리 위탁 및 국외 이전 고지가 필요한지 **검토 필요**(`docs/w0/legal-review-request.md`에 항목 추가 권장). 동의 체크박스(`consent`) 문구에 수탁자·이전 국가를 적을지 함께 판단한다.
- Umami·Plausible·Cloudflare는 쿠키 미사용이라고 명시하나, 배너 불요 여부의 국내법 판단도 **검토 필요**.

## 출처 (확인일 2026-11-12)
- Formspree 요금: https://formspree.io/plans · 처리방침: https://formspree.io/legal/privacy-policy/
- Tally 요금: https://tally.so/pricing
- Umami 요금: https://umami.is/pricing
- Plausible 요금: https://plausible.io/#pricing
- Cloudflare Web Analytics: https://www.cloudflare.com/web-analytics/ · FAQ: https://developers.cloudflare.com/web-analytics/faq/
- GA4 한도: https://support.google.com/analytics/answer/11202874 · 쿠키: https://support.google.com/analytics/answer/11397207
- Google Forms 직접 POST, Web3Forms: 공식 문서 근거 없음(미확인으로 표기)
