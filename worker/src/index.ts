// RoamReady Worker. v1 has one job: revoke Sign in with Apple for account deletion (#12).
// It stores nothing. v2 adds the AI proxy under the same /v1/ routes (#34).
import { createRemoteJWKSet, type JWTVerifyGetKey } from "jose";
import {
  APPLE_KEYS_URL, RevokeError, exchangeCode, makeClientSecret, revokeRefreshToken, verifyIdentityToken, type AppleConfig,
} from "./apple.ts";

export interface Env {
  APPLE_BUNDLE_ID?: string;
  APPLE_TEAM_ID?: string;
  APPLE_KEY_ID?: string;
  /** Worker secret: the `.p8` contents. */
  APPLE_PRIVATE_KEY?: string;
}

export interface Dependencies {
  fetch: (input: string, init: RequestInit) => Promise<Response>;
  appleKeys: JWTVerifyGetKey;
  now: () => Date;
}

export const REVOKE_PATH = "/v1/account/revoke";
const MAX_BODY_BYTES = 16 * 1024;
const MAX_FIELD_LENGTH = 8 * 1024;

// Cached per isolate; jose refreshes it when Apple rotates keys.
const appleKeys = createRemoteJWKSet(APPLE_KEYS_URL);

export default {
  fetch(request: Request, env: Env): Promise<Response> {
    return handle(request, env, { fetch: (input, init) => fetch(input, init), appleKeys, now: () => new Date() });
  },
};

/**
 * POST /v1/account/revoke  {"identityToken": "...", "authorizationCode": "..."}
 *
 * The identity token proves the caller is the Apple user deleting their own account; the
 * authorization code (from the same fresh sign-in) is exchanged for a refresh token, which is
 * revoked. The code must belong to the same user as the identity token. App Attest isn't
 * required in v1 because the endpoint only acts on the caller's own Apple-verified identity.
 */
export async function handle(request: Request, env: Env, deps: Dependencies): Promise<Response> {
  const url = new URL(request.url);
  if (url.pathname !== REVOKE_PATH) return json(404, { error: "not_found" });
  if (request.method !== "POST") return json(405, { error: "method_not_allowed" }, { allow: "POST" });

  const config = appleConfig(env);
  if (!config) {
    console.error("revoke: worker is missing Apple configuration");
    return json(500, { error: "not_configured", message: "Account deletion isn't available right now. Nothing was deleted." });
  }
  try {
    const { identityToken, authorizationCode } = await readBody(request);
    const now = deps.now();
    const subject = await verifyIdentityToken(identityToken, config.bundleID, deps.appleKeys, now);
    const clientSecret = await makeClientSecret(config, now);
    const exchanged = await exchangeCode(authorizationCode, config, clientSecret, deps.fetch);
    if (exchanged.subject !== subject) {
      throw new RevokeError(401, "identity_mismatch", "Sign in with Apple again, then retry.");
    }
    await revokeRefreshToken(exchanged.refreshToken, config, clientSecret, deps.fetch);
    return json(200, { revoked: true });
  } catch (error) {
    if (error instanceof RevokeError) {
      // Codes only: tokens, codes, and keys are never logged.
      console.warn(`revoke: ${error.code}`);
      return json(error.status, { error: error.code, message: error.message });
    }
    console.error("revoke: unexpected failure");
    return json(502, { error: "apple_unavailable", message: "Apple couldn't be reached. Nothing was deleted; try again." });
  }
}

function appleConfig(env: Env): AppleConfig | undefined {
  const { APPLE_BUNDLE_ID: bundleID, APPLE_TEAM_ID: teamID, APPLE_KEY_ID: keyID, APPLE_PRIVATE_KEY: privateKey } = env;
  if (!bundleID || !teamID || !keyID || !privateKey || teamID === "REPLACE_ME" || keyID === "REPLACE_ME") return undefined;
  return { bundleID, teamID, keyID, privateKey };
}

async function readBody(request: Request): Promise<{ identityToken: string; authorizationCode: string }> {
  const invalid = new RevokeError(400, "invalid_request", "The request is missing the Sign in with Apple credentials.");
  if (!(request.headers.get("content-type") ?? "").toLowerCase().startsWith("application/json")) throw invalid;
  const declared = Number(request.headers.get("content-length") ?? "0");
  if (declared > MAX_BODY_BYTES) throw new RevokeError(413, "too_large", "The request is too large.");
  const text = await request.text();
  if (text.length > MAX_BODY_BYTES) throw new RevokeError(413, "too_large", "The request is too large.");
  let body: unknown;
  try { body = JSON.parse(text); } catch { throw invalid; }
  if (typeof body !== "object" || body === null) throw invalid;
  const { identityToken, authorizationCode } = body as Record<string, unknown>;
  for (const value of [identityToken, authorizationCode]) {
    if (typeof value !== "string" || value.length === 0 || value.length > MAX_FIELD_LENGTH) throw invalid;
  }
  return { identityToken: identityToken as string, authorizationCode: authorizationCode as string };
}

function json(status: number, body: Record<string, unknown>, headers: Record<string, string> = {}): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { "content-type": "application/json; charset=utf-8", "cache-control": "no-store", ...headers },
  });
}
