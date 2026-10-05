#!/usr/bin/env node
// Test double for an authenticated HTTP proxy. It answers every request itself
// instead of forwarding it, so the suite needs no network.
//
//   upstream-proxy.js <user:pass> <log-file>
//
// Prints its port. Appends "ok <url>" or "denied <url>" to the log for each
// request, depending on whether the right Proxy-Authorization header arrived.

"use strict";

const http = require("node:http");
const fs = require("node:fs");

const expected = "Basic " + Buffer.from(process.argv[2]).toString("base64");
const log = process.argv[3];

const server = http.createServer((req, res) => {
  const authorised = req.headers["proxy-authorization"] === expected;
  fs.appendFileSync(log, (authorised ? "ok " : "denied ") + req.url + "\n");
  res.writeHead(authorised ? 200 : 407);
  res.end(authorised ? "pong" : "");
});

server.listen(0, "127.0.0.1", () => console.log(server.address().port));
