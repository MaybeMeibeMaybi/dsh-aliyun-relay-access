# Incident: the HTTPS gateway crash-looped on client-aborted TLS handshakes

**Date:** 2026-09-27
**Symptom:** after installing a new CA certificate, the phone still reported the site
certificate as untrusted **and** could no longer reach dsh through the gateway.

## What the logs showed

```
Error: read ECONNRESET
    at TLSWrap.onStreamRead (node:internal/stream_base_commons:216:20)
    throw er; // Unhandled 'error' event
dsh-gateway.service: Main process exited, code=exited, status=1/FAILURE
dsh-gateway.service: Scheduled restart job, restart counter is at 15
```

## Root cause

When a client aborts the connection **during the TLS handshake**, Node emits an
`error` event on the `TLSSocket`. Nothing was listening for it, so the event was
re-thrown as an unhandled error and the whole gateway process exited.

That is exactly what a browser does when the user cancels a certificate warning — and
a public port also gets this treatment continuously from internet scanners. Each crash
wiped the in-memory dsh token, so the next visit rendered "the gateway has not received
this start's token yet". To the user this looked like "the certificate is untrusted and
the site is down".

## Fix

```js
// 1) handshake-phase client errors: count them, never throw
let tlsClientErrors = 0;
server.on("tlsClientError", (error) => {
  tlsClientErrors += 1;
  if (tlsClientErrors <= 5) console.error(`[gateway] TLS handshake aborted by client (ignored): ${error?.code ?? "unknown"}`);
});
server.on("clientError", (_error, socket) => { try { socket.destroy(); } catch {} });

// 2) per-request sockets must not crash the process either
req.on("error", () => {});
res.on("error", () => {});
req.socket?.on("error", () => {});

// 3) top-level safety net: for a public service, staying up beats exiting cleanly
process.on("uncaughtException", (error) => console.error(`[gateway] uncaughtException (contained): ${error?.message}`));
process.on("unhandledRejection", (reason) => console.error(`[gateway] unhandledRejection (contained): ${reason?.message ?? reason}`));
```

Two smaller improvements went in with the same change:

- the gateway now serves the **full certificate chain** (`cat server.crt ca.crt > cert.pem`),
  which is friendlier to stricter clients;
- the same per-socket error guards were added to the entry proxy, which sits behind it.

## How to reproduce the verification

Abort 20 TLS handshakes plus send 10 plaintext junk requests to the port, then check:

```bash
systemctl is-active dsh-gateway        # active
systemctl show dsh-gateway -p NRestarts --value   # 0  (before the fix: it climbed past 15)
```

## Lesson

A public listener must assume every client will vanish mid-handshake. Any `TLSSocket`
or request socket without an `error` handler is a remote kill switch.
