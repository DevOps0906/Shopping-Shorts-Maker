-- topics.product_url: 소재(제품)의 판매·참고 링크. 사용자가 고칠 수 있다.
-- 형식은 http(s) URL, 2048자 이하. 이동(리다이렉트)에 쓰지 않는 참고 값이다(제휴 이동은 affiliate_links 규칙).
-- topics 행 생성은 지금처럼 서버(SR) 전용이라 사용자 INSERT 정책이 없다. 사용자 쓰기는 기존 UPDATE 정책(본인 프로젝트)으로만.

alter table public.topics
  add column product_url text
    check (product_url ~* '^https?://' and char_length(product_url) <= 2048);

grant update (product_url) on public.topics to authenticated;
