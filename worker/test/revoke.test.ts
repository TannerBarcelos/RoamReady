import { test } from "node:test";
import assert from "node:assert/strict";
import { SignJWT, createLocalJWKSet, exportJWK, exportPKCS8, generateKeyPair, jwtVerify, decodeProtectedHeader } from "jose";
import { handle, REVOKE_PATH, type Dependencies, type Env } from "../src/index.ts";
import { APPLE_ISSUER, APPLE_REVOKE_URL, APPLE_TOKEN_URL, MAX_IDENTITY_TOKEN_AGE_SECONDS } from "../src/apple.ts";

const BUNDLE_ID = "com.roamready.app";
const NOW = new Date("2026-10-22T18:00:00Z");
const seconds = (date: Date) => Math.floor(date.getTime() / 1000);

// Apple's identity-token signing key, and an attacker's key with the same kid.
const apple = await generateKeyPair("RS256");
const attacker = await generateKeyPair("RS256");
const appleJWK = { ...(await exportJWK(apple.publicKey)), kid: "apple-1", alg: "RS256", use: "sig" };
const appleKeys = createLocalJWKSet({ keys: [appleJWK] });
// The team's Sign in with Apple key (.p8).
const team = await generateKeyPair("ES256", { extractable: true });
const env: Env = { APPLE_BUNDLE_ID: BUNDLE_ID, APPLE_TEAM_ID: "TEAM123456", APPLE_KEY_ID: "KEY1234567", APPLE_PRIVATE_KEY: await exportPKCS8(team.privateKey) };

async function identityToken(overrides: { sub?: string; aud?: string; iss?: string; iat?: number; exp?: number; key?: CryptoKey } = {}): Promise<string> {
  const iat = overrides.iat ?? seconds(NOW) - 30;
  return new SignJWT({})
    .setProtectedHeader({ alg: "RS256", kid: "apple-1" })
    .setIssuer(overrides.iss ?? APPLE_ISSUER)
    .setAudience(overrides.aud ?? BUNDLE_ID)
    .setSubject(overrides.sub ?? "001234.apple-user")
    .setIssuedAt(iat)
    .setExpirationTime(overrides.exp ?? iat + 600)
    .sign(overrides.key ?? apple.privateKey);
}

interface Call { url: string; form: URLSearchParams }
function appleServer(options: { tokenStatus?: number; revokeStatus?: number; codeOwner?: string } = {}) {
  const calls: Call[] = [];
  const fetch = async (url: string, init: RequestInit): Promise<Response> => {
    calls.push({ url, form: new URLSearchParams(String(init.body)) });
    if (url === APPLE_TOKEN_URL) {
      const status = options.tokenStatus ?? 200;
      if (status !== 200) return new Response(JSON.stringify({ error: "invalid_grant" }), { status });
      const idToken = await identityToken({ sub: options.codeOwner ?? "001234.apple-user" });
      return Response.json({ access_token: "access", refresh_token: "refresh-secret", id_token: idToken, token_type: "Bearer", expires_in: 3600 });
    }
    if (url === APPLE_REVOKE_URL) return new Response(null, { status: options.revokeStatus ?? 200 });
    throw new Error(`unexpected ${url}`);
  };
  return { calls, deps: { fetch, appleKeys, now: () => NOW } satisfies Dependencies };
}

function request(body: unknown, init: { method?: string; path?: string; contentType?: string } = {}): Request {
  return new Request(`https://worker.example${init.path ?? REVOKE_PATH}`, {
    method: init.method ?? "POST",
    headers: { "content-type": init.contentType ?? "application/json" },
    ...(init.method === "GET" ? {} : { body: typeof body === "string" ? body : JSON.stringify(body) }),
  });
}

async function revoke(body: unknown, server = appleServer(), environment: Env = env) {
  const response = await handle(request(body), environment, server.deps);
  return { status: response.status, body: await response.json() as Record<string, unknown>, calls: server.calls };
}

test("a fresh, valid identity token and code revoke the user's token", async () => {
  const result = await revoke({ identityToken: await identityToken(), authorizationCode: "code-123" });
  assert.equal(result.status, 200);
  assert.deepEqual(result.body, { revoked: true });
  assert.deepEqual(result.calls.map((call) => call.url), [APPLE_TOKEN_URL, APPLE_REVOKE_URL]);
  const [token, revocation] = result.calls as [Call, Call];
  assert.equal(token.form.get("grant_type"), "authorization_code");
  assert.equal(token.form.get("code"), "code-123");
  assert.equal(token.form.get("client_id"), BUNDLE_ID);
  assert.equal(revocation.form.get("token"), "refresh-secret");
  assert.equal(revocation.form.get("token_type_hint"), "refresh_token");
  assert.equal(revocation.form.get("client_id"), BUNDLE_ID);

  // The client secret is an ES256 JWT that Apple can verify with the team's public key.
  const secret = token.form.get("client_secret") ?? "";
  assert.equal(revocation.form.get("client_secret"), secret);
  assert.deepEqual(decodeProtectedHeader(secret), { alg: "ES256", kid: "KEY1234567" });
  const { payload } = await jwtVerify(secret, team.publicKey, { currentDate: NOW, audience: APPLE_ISSUER, issuer: "TEAM123456", subject: BUNDLE_ID });
  assert.ok((payload.exp ?? 0) - (payload.iat ?? 0) <= 300);
});

for (const [name, makeToken] of [
  ["expired", () => identityToken({ iat: seconds(NOW) - 900, exp: seconds(NOW) - 300 })],
  ["for another app", () => identityToken({ aud: "com.someone.else" })],
  ["from another issuer", () => identityToken({ iss: "https://evil.example" })],
  ["forged with another key", () => identityToken({ key: attacker.privateKey })],
  ["too old to prove a fresh sign-in", () => identityToken({ iat: seconds(NOW) - MAX_IDENTITY_TOKEN_AGE_SECONDS - 120, exp: seconds(NOW) + 600 })],
  ["not a JWT", async () => "not-a-token"],
] as const) {
  test(`an identity token ${name} is rejected before calling Apple`, async () => {
    const result = await revoke({ identityToken: await makeToken(), authorizationCode: "code-123" });
    assert.equal(result.status, 401);
    assert.equal(result.body.error, "invalid_identity_token");
    assert.equal(result.calls.length, 0);
  });
}

test("a code belonging to a different Apple user is not revoked", async () => {
  const result = await revoke({ identityToken: await identityToken(), authorizationCode: "someone-elses-code" }, appleServer({ codeOwner: "009999.other-user" }));
  assert.equal(result.status, 401);
  assert.equal(result.body.error, "identity_mismatch");
  assert.deepEqual(result.calls.map((call) => call.url), [APPLE_TOKEN_URL]);
});

test("missing or malformed credentials are a bad request", async () => {
  for (const body of [{}, { identityToken: await identityToken() }, { identityToken: 1, authorizationCode: "c" }, "not json", null]) {
    const result = await revoke(body);
    assert.equal(result.status, 400, JSON.stringify(body));
    assert.equal(result.body.error, "invalid_request");
    assert.equal(result.calls.length, 0);
  }
});

test("an expired or reused authorization code asks for a fresh sign-in", async () => {
  const result = await revoke({ identityToken: await identityToken(), authorizationCode: "used" }, appleServer({ tokenStatus: 400 }));
  assert.equal(result.status, 400);
  assert.equal(result.body.error, "invalid_authorization_code");
});

test("Apple failures are reported, never as success", async () => {
  for (const server of [appleServer({ tokenStatus: 503 }), appleServer({ revokeStatus: 500 })]) {
    const result = await revoke({ identityToken: await identityToken(), authorizationCode: "code" }, server);
    assert.equal(result.status, 502);
    assert.equal(result.body.error, "apple_unavailable");
    assert.notEqual(result.body.revoked, true);
  }
});

test("an unconfigured worker refuses without calling Apple", async () => {
  const result = await revoke({ identityToken: await identityToken(), authorizationCode: "code" }, appleServer(),
    { ...env, APPLE_TEAM_ID: "REPLACE_ME" });
  assert.equal(result.status, 500);
  assert.equal(result.body.error, "not_configured");
  assert.equal(result.calls.length, 0);
});

test("only POST /v1/account/revoke is served", async () => {
  const server = appleServer();
  assert.equal((await handle(request({}, { path: "/" }), env, server.deps)).status, 404);
  const get = await handle(request(undefined, { method: "GET" }), env, server.deps);
  assert.equal(get.status, 405);
  assert.equal(get.headers.get("allow"), "POST");
  const text = await handle(request("x", { contentType: "text/plain" }), env, server.deps);
  assert.equal(text.status, 400);
});

test("responses never echo tokens, codes, or keys", async () => {
  const token = await identityToken();
  for (const server of [appleServer(), appleServer({ tokenStatus: 400 }), appleServer({ codeOwner: "other" }), appleServer({ revokeStatus: 500 })]) {
    const response = await handle(request({ identityToken: token, authorizationCode: "code-xyz" }), env, server.deps);
    const text = await response.text();
    for (const secret of [token, "code-xyz", "refresh-secret", env.APPLE_PRIVATE_KEY ?? ""]) assert.ok(!text.includes(secret));
    assert.equal(response.headers.get("cache-control"), "no-store");
  }
});
