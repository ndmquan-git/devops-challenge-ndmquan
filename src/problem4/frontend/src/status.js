export function statusLine(environment, version) {
  return version ? `${environment}: API ${version}` : `${environment}: API unreachable`;
}
