#!/usr/bin/env node
// Local forwarder for one opencode run.
//
// The upstream proxy URL, with its credentials, arrives in FREELOADER_UPSTREAM_PROXY.
// This process listens on a random port on 127.0.0.1, prints that port, and relays
// everything to the upstream. The agent is pointed at http://127.0.0.1:<port>,
// so a model with a shell can read its own environment without learning the
// credentials.
//
// Upstream protocols (see vendor/pi-swarm/egress.ts for the canonical parser):
//   http://, https:// — classic HTTP proxy (Proxy-Authorization injected).
//   socks5://, socks5h://, socks:// — SOCKS5 CONNECT tunnel per target.
//
// Outcomes are appended to stderr as "ok" or "fail <reason>" lines, one per
// connection, so the caller can tell a dead exit from a model that failed.

"use strict";

const http = require("node:http");
const https = require("node:https");
const net = require("node:net");
const tls = require("node:tls");

const upstream = new URL(process.env.FREELOADER_UPSTREAM_PROXY || "");
delete process.env.FREELOADER_UPSTREAM_PROXY;

const scheme = upstream.protocol.replace(/:$/, "").toLowerCase();
const isSocks = scheme === "socks" || scheme === "socks5" || scheme === "socks5h";
const isHttpProxy = scheme === "http" || scheme === "https";

if (!isSocks && !isHttpProxy) {
  console.error("fail unsupported upstream protocol " + upstream.protocol);
  process.exit(2);
}

const proxyHost = upstream.hostname;
const proxyPort =
  Number(upstream.port) || (scheme === "https" ? 443 : scheme === "http" ? 80 : 1080);
const proxyUser = upstream.username ? decodeURIComponent(upstream.username) : "";
const proxyPass = upstream.password ? decodeURIComponent(upstream.password) : "";
const basicAuth =
  upstream.username || upstream.password
    ? "Basic " + Buffer.from(`${proxyUser}:${proxyPass}`).toString("base64")
    : null;

function dialProxyDirect() {
  return scheme === "https"
    ? tls.connect({ host: proxyHost, port: proxyPort, servername: proxyHost })
    : net.connect({ host: proxyHost, port: proxyPort });
}

// --- SOCKS5 ---------------------------------------------------------------
// Minimal client: greeting (+ user/pass when the URL carries credentials)
// then CONNECT <targetHost>:<targetPort>. Returns a socket already
// connected to the target.
function socksDial(targetHost, targetPort) {
  return new Promise((resolve, reject) => {
    const sock = net.connect({ host: proxyHost, port: proxyPort });
    const timer = setTimeout(() => {
      sock.destroy();
      reject(new Error("timeout"));
    }, 20000);
    let settled = false;
    const done = (err, result) => {
      if (settled) return;
      settled = true;
      clearTimeout(timer);
      // Handshake listeners are no longer needed; the socket itself stays open.
      sock.removeAllListeners("data");
      if (err) {
        sock.destroy();
        reject(err);
      } else resolve(result);
    };
    sock.on("error", (err) => done(err));

    // Single buffered reader: avoids unshift/re-emit pitfalls when the
    // server coalesces greeting + CONNECT replies in one segment.
    let buf = Buffer.alloc(0);
    const waiters = [];
    const dispatch = () => {
      while (waiters.length && buf.length >= waiters[0].n) {
        const w = waiters.shift();
        const out = buf.subarray(0, w.n);
        buf = buf.subarray(w.n);
        w.res(out);
      }
    };
    sock.on("data", (chunk) => {
      buf = Buffer.concat([buf, chunk]);
      dispatch();
    });
    const readExact = (n) =>
      new Promise((res, rej) => {
        waiters.push({ n, res, rej });
        dispatch();
      });

    (async () => {
      await new Promise((res, rej) => {
        sock.once("connect", res);
        sock.once("error", rej);
      });
      const needsAuth = Boolean(proxyUser || proxyPass);
      sock.write(Buffer.from([0x05, 0x01, needsAuth ? 0x02 : 0x00]));
      const method = await readExact(2);
      if (method[0] !== 0x05) throw new Error("bad socks version");
      if (method[1] === 0xff) throw new Error("no acceptable auth");
      if (method[1] === 0x02) {
        const user = Buffer.from(proxyUser, "utf8");
        const pass = Buffer.from(proxyPass, "utf8");
        if (user.length > 255 || pass.length > 255) throw new Error("credentials too long");
        sock.write(
          Buffer.concat([
            Buffer.from([0x01, user.length]),
            user,
            Buffer.from([pass.length]),
            pass,
          ]),
        );
        const authResp = await readExact(2);
        if (authResp[1] !== 0x00) throw new Error("auth failed");
      } else if (method[1] !== 0x00) {
        throw new Error("unsupported auth method");
      }
      let atyp;
      let addrBuf;
      if (net.isIP(targetHost) === 4) {
        atyp = 0x01;
        addrBuf = Buffer.from(targetHost.split(".").map((o) => Number(o)));
      } else if (net.isIP(targetHost) === 6) {
        atyp = 0x04;
        addrBuf = Buffer.from(targetHost.split(":").flatMap((h) => {
          if (h === "") return [];
          const n = parseInt(h || "0", 16);
          return [(n >> 8) & 0xff, n & 0xff];
        }));
        if (addrBuf.length !== 16) {
          atyp = 0x03;
          const hb = Buffer.from(targetHost, "utf8");
          addrBuf = Buffer.concat([Buffer.from([hb.length]), hb]);
        }
      } else {
        atyp = 0x03;
        const hb = Buffer.from(targetHost, "utf8");
        addrBuf = Buffer.concat([Buffer.from([hb.length]), hb]);
      }
      const portBuf = Buffer.alloc(2);
      portBuf.writeUInt16BE(targetPort, 0);
      sock.write(Buffer.concat([Buffer.from([0x05, 0x01, 0x00, atyp]), addrBuf, portBuf]));
      const head = await readExact(4);
      if (head[0] !== 0x05) throw new Error("bad socks reply");
      if (head[1] !== 0x00) throw new Error("socks connect failed " + head[1]);
      const rAtyp = head[3];
      let remaining = 0;
      if (rAtyp === 0x01) remaining = 4 + 2;
      else if (rAtyp === 0x04) remaining = 16 + 2;
      else if (rAtyp === 0x03) {
        const lenByte = await readExact(1);
        remaining = lenByte[0] + 2;
      } else throw new Error("bad socks atyp");
      await readExact(remaining);
      done(null, sock);
    })().catch(done);
  });
}

function targetFromAbsoluteUrl(absoluteUrl) {
  const parsed = new URL(absoluteUrl);
  const port =
    Number(parsed.port) || (parsed.protocol === "https:" ? 443 : 80);
  return { host: parsed.hostname, port, path: parsed.pathname + parsed.search };
}

const server = http.createServer((req, res) => {
  if (isSocks) {
    // Plain HTTP via SOCKS: tunnel to the target, then speak origin-form
    // HTTP over it. createConnection reuses the SOCKS socket so Node still
    // parses the origin's response for us.
    let target;
    try {
      target = targetFromAbsoluteUrl(req.url);
    } catch {
      console.error("fail bad request url");
      res.writeHead(400);
      res.end();
      return;
    }
    socksDial(target.host, target.port).then(
      (up) => {
        console.error("ok");
        const headers = { ...req.headers };
        delete headers["proxy-authorization"];
        const out = http.request(
          {
            host: target.host,
            port: target.port,
            method: req.method,
            path: target.path,
            headers,
            createConnection: () => up,
          },
          (back) => {
            res.writeHead(back.statusCode || 502, back.headers);
            back.pipe(res);
          },
        );
        out.on("error", () => {
          try {
            res.writeHead(502);
          } catch {}
          res.end();
        });
        req.pipe(out);
      },
      (err) => {
        console.error("fail " + (err.code || err.message || "socks"));
        res.writeHead(502);
        res.end();
      },
    );
    return;
  }

  // Plain HTTP via HTTP proxy: hand the absolute-URI request upstream.
  const headers = { ...req.headers };
  if (basicAuth) headers["proxy-authorization"] = basicAuth;
  const requester = scheme === "https" ? https : http;
  const out = requester.request(
    { host: proxyHost, port: proxyPort, method: req.method, path: req.url, headers },
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
  const finishFail = (reason, up) => {
    console.error("fail " + reason);
    try {
      client.end("HTTP/1.1 502 Bad Gateway\r\n\r\n");
    } catch {}
    if (up) up.destroy();
  };

  if (isSocks) {
    const [host, portStr] = String(req.url).split(":");
    const port = Number(portStr) || 443;
    socksDial(host, port).then(
      (up) => {
        console.error("ok");
        client.write("HTTP/1.1 200 Connection Established\r\n\r\n");
        if (head && head.length) up.write(head);
        up.pipe(client);
        client.pipe(up);
        up.on("error", () => client.destroy());
        client.on("error", () => up.destroy());
      },
      (err) => finishFail(err.code || err.message || "socks", null),
    );
    return;
  }

  const up = dialProxyDirect();
  let settled = false;
  const fail = (reason) => {
    if (settled) return;
    settled = true;
    finishFail(reason, up);
  };
  up.setTimeout(20000, () => fail("timeout"));
  up.on("error", (err) => fail(err.code || "error"));
  client.on("error", () => up.destroy());

  up.once(scheme === "https" ? "secureConnect" : "connect", () => {
    up.write(
      "CONNECT " + req.url + " HTTP/1.1\r\nHost: " + req.url + "\r\n" +
        (basicAuth ? "Proxy-Authorization: " + basicAuth + "\r\n" : "") + "\r\n",
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
