# RoamReady Worker

**Not deployed in v1.** v1 has no accounts and no backend (see [identity contract](../docs/account-and-offline-contract.md)).

This Cloudflare Worker was written for Sign in with Apple token revocation (#12), before Sign in with Apple was removed from v1. Its `POST /v1/account/revoke` endpoint is only needed if Sign in with Apple returns. The project setup is the starting point for v2's server work (#34: remote AI, quotas, StoreKit entitlement checks), and so are its staging/production environments, Wrangler config, CI (typecheck, `node:test`, dry-run bundle, manual deploy), and secret handling.

```sh
npm ci
npm test          # node:test with generated keys
npm run typecheck
```

What the revoke endpoint does: it verifies a Sign in with Apple identity token against Apple's keys, exchanges the authorization code, checks both belong to the same Apple user, and revokes the refresh token, using a client secret signed per request from the `APPLE_PRIVATE_KEY` Worker secret.
