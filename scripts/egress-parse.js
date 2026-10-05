#!/usr/bin/env node
// Egress list parser for freeloader.
//
// Derived from pi-swarm's src/egress.ts (vendored at vendor/pi-swarm/egress.ts).
// Same entry forms, same fail-closed country filter, but dependency-free plain
// Node so scripts/lib.sh can call it without a TS toolchain or undici.
//
// Accepted per entry (country always optional):
//   socks5://127.0.0.1:1080#US
//   socks5://127.0.0.1:1080#country=DE
//   http://127.0.0.1:8080?country=FR
//   US=socks5://127.0.0.1:1080
//   https://user:pass@proxy.example:8080
//
// Protocols: http, https, socks, socks5, socks5h (socks:// aliases to socks5).
//
// Input precedence (mirrors pi-swarm + freeloader):
//   raw = FREELOADER_PROXIES || PI_SWARM_PROXIES
//   file = FREELOADER_PROXIES_FILE || PI_SWARM_PROXIES_FILE || --proxies-file
//   want = --countries (from freeloader.config.json) ||
//          PI_SWARM_EGRESS_COUNTRIES || FREELOADER_EGRESS_COUNTRIES
//
// File shapes:
//   - JSON array: ["socks5://...#US", {"url":"...","country":"DE"}]
//   - env file with FREELOADER_PROXIES= / PI_SWARM_PROXIES= line
//   - plain list, one per line (commas also split), # comments stripped
//
// Output: one "COUNTRY<TAB>URL" per line on stdout (COUNTRY empty when untagged).
// Exit 0 even when empty; the caller decides fail-closed.

"use strict";

const fs = require("node:fs");

function normalizeCountry(raw) {
  if (!raw) return undefined;
  const upper = String(raw).trim().toUpperCase();
  return /^[A-Z]{2}$/.test(upper) ? upper : undefined;
}

function normalizeProtocol(protocol) {
  const lower = String(protocol).replace(/:$/, "").toLowerCase();
  if (lower === "http") return "http";
  if (lower === "https") return "https";
  if (lower === "socks5" || lower === "socks5h") return lower;
  if (lower === "socks") return "socks5";
  return undefined;
}

function parseEgressEntry(entry, countryHint) {
  const trimmed = String(entry).trim();
  if (!trimmed) return undefined;
  let country = normalizeCountry(countryHint);
  let urlText = trimmed;

  const prefixMatch = /^([A-Za-z]{2})=(.+)$/.exec(trimmed);
  if (prefixMatch && prefixMatch[1] && prefixMatch[2]) {
    const c = normalizeCountry(prefixMatch[1]);
    if (c) {
      country = c;
      urlText = prefixMatch[2].trim();
    }
  }

  const hashIndex = urlText.indexOf("#");
  if (hashIndex !== -1) {
    const fragment = urlText.slice(hashIndex + 1);
    const fragCountry = fragment.startsWith("country=")
      ? normalizeCountry(fragment.slice("country=".length))
      : normalizeCountry(fragment);
    if (fragCountry) country = fragCountry;
    urlText = urlText.slice(0, hashIndex);
  }

  let parsed;
  try {
    parsed = new URL(urlText);
  } catch {
    return undefined;
  }
  const protocol = normalizeProtocol(parsed.protocol);
  if (!protocol) return undefined;
  if (!parsed.hostname) return undefined;

  const queryCountry = normalizeCountry(parsed.searchParams.get("country"));
  if (queryCountry) {
    country = queryCountry;
    parsed.searchParams.delete("country");
  }
  // Drop a bare fragment left over; only country fragments are documented.
  parsed.hash = "";
  // Preserve the original spelling (no trailing-slash normalization) so
  // cksum(url) ids stay stable with pre-pi-swarm state files. Only when a
  // ?country= param was stripped do we need the normalized form.
  const url = queryCountry ? parsed.toString() : urlText;

  return { url, country, protocol };
}

function parseList(raw) {
  const out = [];
  for (const chunk of String(raw || "").split(/[,\n]+/)) {
    const entry = chunk.trim();
    if (!entry) continue;
    // Allow full-line comments when the raw came from a plain-list file.
    if (entry.startsWith("#")) continue;
    const proxy = parseEgressEntry(entry);
    if (proxy) out.push(proxy);
  }
  return out;
}

function parseCountryFilter(raw) {
  if (!raw || !String(raw).trim()) return undefined;
  const codes = String(raw)
    .split(/[,\s]+/)
    .map((c) => c.trim().toUpperCase())
    .filter((c) => /^[A-Z]{2}$/.test(c));
  const uniq = [...new Set(codes)];
  return uniq.length ? uniq : undefined;
}

function unquote(s) {
  const t = String(s).trim();
  if (t.length >= 2 && t.startsWith('"') && t.endsWith('"')) {
    try {
      return JSON.parse(t);
    } catch {
      return t.slice(1, -1);
    }
  }
  if (t.length >= 2 && t.startsWith("'") && t.endsWith("'")) return t.slice(1, -1);
  return t;
}

function proxiesFromFileContent(content) {
  const trimmed = String(content).trim();
  if (!trimmed) return [];
  // JSON array shape from pi-swarm: strings or {url, country} objects.
  if (trimmed.startsWith("[")) {
    try {
      const parsed = JSON.parse(trimmed);
      if (Array.isArray(parsed)) {
        const out = [];
        for (const item of parsed) {
          if (typeof item === "string") {
            const p = parseEgressEntry(item);
            if (p) out.push(p);
          } else if (item && typeof item === "object") {
            const url = typeof item.url === "string" ? item.url : "";
            const country = typeof item.country === "string" ? item.country : "";
            if (!url) continue;
            const p = parseEgressEntry(country ? `${country}=${url}` : url);
            // parseEgressEntry drops invalid country prefixes to global;
            // re-apply a valid object country explicitly.
            if (p && normalizeCountry(country)) p.country = normalizeCountry(country);
            if (p) out.push(p);
          }
        }
        return out;
      }
    } catch {
      // Fall through to line parsing.
    }
  }
  const envLine = String(content)
    .split("\n")
    .map((l) => l.trim())
    .find((l) => /^(export\s+)?(FREELOADER_PROXIES|PI_SWARM_PROXIES)=/.test(l));
  if (envLine) {
    const value = envLine.replace(/^(export\s+)?(FREELOADER_PROXIES|PI_SWARM_PROXIES)=/, "");
    return parseList(unquote(value));
  }
  // Plain list: strip comments, keep entries.
  const lines = String(content)
    .split("\n")
    .map((l) => {
      const noComment = l.split("#").length > 1 && /^[ \t]*#/.test(l) ? "" : l;
      // Only full-line comments are stripped; inline #CC suffixes are significant.
      return noComment;
    });
  return parseList(lines.join("\n"));
}

function main() {
  const args = process.argv.slice(2);
  let proxiesFileArg = "";
  let countriesArg = "";
  for (let i = 0; i < args.length; i++) {
    if (args[i] === "--proxies-file" && i + 1 < args.length) proxiesFileArg = args[++i];
    else if (args[i] === "--countries" && i + 1 < args.length) countriesArg = args[++i];
  }

  const env = process.env;
  let raw = env.FREELOADER_PROXIES || env.PI_SWARM_PROXIES || "";
  const file = env.FREELOADER_PROXIES_FILE || env.PI_SWARM_PROXIES_FILE || proxiesFileArg || "";

  let proxies = [];
  if (raw) {
    proxies = parseList(raw);
  } else if (file) {
    let content;
    try {
      content = fs.readFileSync(file, "utf8");
    } catch (err) {
      console.error(`egress: cannot read proxies file ${file}`);
      process.exit(2);
    }
    proxies = proxiesFromFileContent(content);
  }

  const want =
    parseCountryFilter(countriesArg) ||
    parseCountryFilter(env.PI_SWARM_EGRESS_COUNTRIES) ||
    parseCountryFilter(env.FREELOADER_EGRESS_COUNTRIES);

  for (const p of proxies) {
    if (want && want.length) {
      if (!p.country || !want.includes(p.country)) continue;
    }
    console.log(`${p.country || ""}\t${p.url}`);
  }
}

main();
