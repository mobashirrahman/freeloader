# Vendored pi-swarm egress pool

`egress.ts` is a verbatim copy of `src/egress.ts` from
`/Users/mobashirrahman/Documents/pi-swarm` (the "PySwarm" folder).

It is the canonical reference for pool semantics:

* entry forms (`CC=url`, `url#CC`, `url#country=CC`, `url?country=CC`)
* protocols (`http`, `https`, `socks5`/`socks5h`, `socks://` alias)
* fail-closed country filter (globals never substitute)
* redaction (`protocol://host:port`, never credentials)
* TTL blacklist + `EgressExhaustedError` reasons

Because this repo runs on bash + plain Node with no TS toolchain or
`undici` dependency, the copy is not imported directly. Instead:

* `scripts/egress-parse.js` re-implements its parsing/filtering in
  dependency-free JS (same forms, JSON file + `PI_SWARM_*` env support).
  `scripts/lib.sh:load_egress()` calls it.
* `scripts/egress-forward.js` implements the matching forwarder, including
  SOCKS5 `CONNECT` tunnelling, so `socks5://` exits work here too.

If you update the upstream file, re-copy it here and port any parsing or
protocol change into those two scripts.
