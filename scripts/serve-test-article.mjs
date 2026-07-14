import { createReadStream } from "node:fs";
import { createServer } from "node:http";
import { env, stdout } from "node:process";
import { fileURLToPath, URL } from "node:url";

const articlePath = fileURLToPath(new URL("../apps/browser-extension/tests/fixtures/test-article.html", import.meta.url));
const port = Number(env.PORT ?? 4173);
const server = createServer((request, response) => {
  if (request.url !== "/" && request.url !== "/test-article.html") {
    response.writeHead(404, { "content-type": "text/plain; charset=utf-8" });
    response.end("Not found");
    return;
  }
  response.writeHead(200, { "content-type": "text/html; charset=utf-8", "cache-control": "no-store" });
  createReadStream(articlePath).pipe(response);
});

server.listen(port, "127.0.0.1", () => {
  stdout.write(`LinkDigest test article: http://127.0.0.1:${port}/test-article.html\n`);
});
