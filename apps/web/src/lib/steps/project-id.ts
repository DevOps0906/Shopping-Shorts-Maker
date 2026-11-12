const UUID_PATTERN = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** projects.id(uuid) 모양 검사. URL·서버 액션 입력을 DB에 넘기기 전에 거른다. */
export function isProjectId(value: string) {
  return UUID_PATTERN.test(value);
}
