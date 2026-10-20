// A stand-in for APNs over plain HTTP/2 (h2c), for local end-to-end runs: logs every request as one
// JSON line and answers like Apple (200 with apns-id; 410 Unregistered for tokens starting "dead").
// usage: node scripts/fake-apns.mjs <port> <log.jsonl>
import fs from "node:fs";
import http2 from "node:http2";
import crypto from "node:crypto";

const [port = "8443", log = "fake-apns.jsonl"] = process.argv.slice(2);
const server = http2.createServer();
server.on("stream", (stream, headers) => {
  let body = "";
  stream.setEncoding("utf8");
  stream.on("data", (chunk) => (body += chunk));
  stream.on("end", () => {
    const token = String(headers[":path"] ?? "").split("/").pop();
    fs.appendFileSync(log, JSON.stringify({ path: headers[":path"], headers, body: JSON.parse(body || "{}") }) + "\n");
    if (token.startsWith("dead")) {
      stream.respond({ ":status": 410, "apns-id": crypto.randomUUID() });
      stream.end(JSON.stringify({ reason: "Unregistered" }));
    } else {
      stream.respond({ ":status": 200, "apns-id": crypto.randomUUID() });
      stream.end();
    }
  });
});
server.listen(Number(port), "127.0.0.1", () => console.log(`fake APNs on h2c://127.0.0.1:${port}`));
