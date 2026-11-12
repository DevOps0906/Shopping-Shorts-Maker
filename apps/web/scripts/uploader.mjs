// YouTube 업로더 진입 스크립트(task-024a). Compose 서비스 uploader 와 `pnpm --filter web uploader` 가 실행한다.
//   node --conditions=react-server scripts/uploader.mjs [--once]
// - web 앱과 같은 소스(src/server/**)를 그대로 쓴다. 번들러 없이 Node 모듈 훅으로 `@/` 경로와 .ts 를 읽고,
//   TypeScript(devDependency)의 transpileModule 로 타입만 지운다.
// - `--conditions=react-server` 로 server-only 가 빈 모듈이 된다(서버 전용 코드만 부르는 프로세스).
import { existsSync, readFileSync, statSync } from "node:fs";
import { registerHooks } from "node:module";
import path from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";
import ts from "typescript";

const srcDir = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../src");

function tsCandidate(url) {
  const file = fileURLToPath(url);
  for (const f of [file, `${file}.ts`, `${file}.tsx`, path.join(file, "index.ts")]) {
    if (existsSync(f) && statSync(f).isFile()) return pathToFileURL(f).href;
  }
  return null;
}

registerHooks({
  resolve(specifier, context, nextResolve) {
    let url = null;
    if (specifier.startsWith("@/")) {
      url = pathToFileURL(path.join(srcDir, specifier.slice(2))).href;
    } else if ((specifier.startsWith("./") || specifier.startsWith("../")) && context.parentURL?.startsWith("file:")) {
      url = new URL(specifier, context.parentURL).href;
    }
    if (url) {
      const found = tsCandidate(url);
      if (found) return { url: found, shortCircuit: true };
    }
    return nextResolve(specifier, context);
  },
  load(url, context, nextLoad) {
    if (url.startsWith("file:") && /\.tsx?$/.test(url)) {
      const fileName = fileURLToPath(url);
      const { outputText } = ts.transpileModule(readFileSync(fileName, "utf8"), {
        fileName,
        compilerOptions: { module: ts.ModuleKind.ESNext, target: ts.ScriptTarget.ES2022, jsx: ts.JsxEmit.ReactJSX },
      });
      return { format: "module", source: outputText, shortCircuit: true };
    }
    return nextLoad(url, context);
  },
});

const { main } = await import("../src/server/publish/uploader-main.ts");
await main(process.argv.slice(2));
