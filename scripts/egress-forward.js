#!/usr/bin/env node
// Local forwarder for one opencode run.
//
// The upstream proxy URL, with its credentials, arrives in FREELOADER_UPSTREAM_PROXY.
// This process listens on a random port on 127.0.0.1, prints that port, and relays
// everything to the upstream, adding the Proxy-Authorization header itself. The
// agent is pointed at http://127.0.0.1:<port>, so a model with a shell can read
// its own environment without learning the credentials.
//
// Outcomes are appended to stderr as "ok" or "fail <reason>" lines, one per
// connection, so the caller can tell a dead exit from a model that failed.

"use strict";

const http = require("node:http");
const net = require("node:net");
const tls = require("node:tls");

const upstream = new URL(process.env.FREELOADER_UPSTREAM_PROXY || "");
delete process.env.FREELOADER_UPSTREAM_PROXY;

if (upstream.protocol !== "http:" && upstream.protocol !== "https:") {
  console.error("fail unsupported upstream protocol " + upstream.protocol);
  process.exit(2);
}

const port = Number(upstream.port) || (upstream.protocol === "https:" ? 443 : 80);
const auth = upstream.username
  ? "Basic " +
    Buffer.from(
      decodeURIComponent(upstream.username) + ":" + decodeURIComponent(upstream.password),
    ).toString("base64")
  : null;

function dial() {
  return upstream.protocol === "https:"
    ? tls.connect({ host: upstream.hostname, port, servername: upstream.hostname })
    : net.connect({ host: upstream.hostname, port });
}

const server = http.createServer((req, res) => {
  // Plain HTTP: hand the absolute-URI request to the upstream proxy.
  const headers = { ...req.headers };
  if (auth) headers["proxy-authorization"] = auth;
  const out = http.request(
    { host: upstream.hostname, port, method: req.method, path: req.url, headers },
    (back) => {
      console.error(back.statusCode === 407 ? "fail upstream rejected credentials" : "ok");
      res.writeHead(back.statusCode || 502, back.headers);
      back.pipe(res);
    },
  );
  out.on("error", (err) => {
    console.error("fail " + err.code);
    res.writeHead(502);
    res.end();
  });
  req.pipe(out);
});

// HTTPS: open a tunnel through the upstream, then splice the two sockets.
server.on("connect", (req, client, head) => {
  const up = dial();
  let settled = false;
  const fail = (reason) => {
    if (settled) return;
    settled = true;
    console.error("fail " + reason);
    client.end("HTTP/1.1 502 Bad Gateway\r\n\r\n");
    up.destroy();
  };
  up.setTimeout(20000, () => fail("timeout"));
  up.on("error", (err) => fail(err.code || "error"));
  client.on("error", () => up.destroy());

  up.once(upstream.protocol === "https:" ? "secureConnect" : "connect", () => {
    up.write(
      "CONNECT " + req.url + " HTTP/1.1\r\nHost: " + req.url + "\r\n" +
        (auth ? "Proxy-Authorization: " + auth + "\r\n" : "") + "\r\n",
    );
  });

  let buffered = Buffer.alloc(0);
  const onData = (chunk) => {
    buffered = Buffer.concat([buffered, chunk]);
    const end = buffered.indexOf("\r\n\r\n");
    if (end === -1) return;
    up.removeListener("data", onData);
    const status = Number(buffered.subarray(0, 12).toString().split(" ")[1]);
    if (status !== 200) return fail("upstream answered " + status);
    settled = true;
    up.setTimeout(0);
    console.error("ok");
    client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
    const rest = buffered.subarray(end + 4);
    if (rest.length) client.write(rest);
    if (head.length) up.write(head);
    up.pipe(client);
    client.pipe(up);
  };
  up.on("data", onData);
});

server.listen(0, "127.0.0.1", () => console.log(server.address().port));
