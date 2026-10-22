// Sign in with Apple REST calls for account deletion. Apple's guidance for deleting an account
// created with Sign in with Apple: exchange an authorization code for a refresh token, then
// revoke it (`/auth/token`, `/auth/revoke`). Both need a client secret: an ES256 JWT signed
// with the team's private key, which therefore lives only here, as a Worker secret.
import { SignJWT, decodeJwt, importPKCS8, jwtVerify, type JWTVerifyGetKey } from "jose";

export const APPLE_ISSUER = "https://appleid.apple.com";
export const APPLE_KEYS_URL = new URL("https://appleid.apple.com/auth/keys");
export const APPLE_TOKEN_URL = "https://appleid.apple.com/auth/token";
export const APPLE_REVOKE_URL = "https://appleid.apple.com/auth/revoke";
/** An identity token older than this isn't accepted as proof the owner is deleting their account now. */
export const MAX_IDENTITY_TOKEN_AGE_SECONDS = 10 * 60;
/** Apple allows up to six months; the secret is single-use here, so it expires quickly. */
export const CLIENT_SECRET_LIFETIME_SECONDS = 5 * 60;

export interface AppleConfig {
  /** The app's bundle ID: the identity token's audience and the `client_id`. */
  bundleID: string;
  teamID: string;
  keyID: string;
  /** PKCS #8 PEM contents of the `.p8` key. */
  privateKey: string;
}

/** A failure with a status and a stable code for the app. Never carries tokens or keys. */
export class RevokeError extends Error {
  readonly status: number;
  readonly code: string;
  constructor(status: number, code: string, message: string) {
    super(message);
    this.status = status;
    this.code = code;
  }
}

/** Verifies signature (Apple's published keys), issuer, audience, expiry, and freshness. */
export async function verifyIdentityToken(token: string, bundleID: string, keys: JWTVerifyGetKey, now: Date): Promise<string> {
  let subject: unknown;
  try {
    const { payload } = await jwtVerify(token, keys, {
      issuer: APPLE_ISSUER,
      audience: bundleID,
      algorithms: ["RS256"],
      currentDate: now,
      maxTokenAge: MAX_IDENTITY_TOKEN_AGE_SECONDS,
      clockTolerance: 30,
    });
    subject = payload.sub;
  } catch {
    throw new RevokeError(401, "invalid_identity_token", "Sign in with Apple again, then retry.");
  }
  if (typeof subject !== "string" || subject.length === 0) {
    throw new RevokeError(401, "invalid_identity_token", "Sign in with Apple again, then retry.");
  }
  return subject;
}

/** The ES256 client secret for Apple's token and revoke endpoints, signed at request time. */
export async function makeClientSecret(config: AppleConfig, now: Date): Promise<string> {
  const key = await importPKCS8(config.privateKey, "ES256");
  const issuedAt = Math.floor(now.getTime() / 1000);
  return new SignJWT({})
    .setProtectedHeader({ alg: "ES256", kid: config.keyID })
    .setIssuer(config.teamID)
    .setIssuedAt(issuedAt)
    .setExpirationTime(issuedAt + CLIENT_SECRET_LIFETIME_SECONDS)
    .setAudience(APPLE_ISSUER)
    .setSubject(config.bundleID)
    .sign(key);
}

type Fetch = (input: string, init: RequestInit) => Promise<Response>;

function form(fields: Record<string, string>): RequestInit {
  return {
    method: "POST",
    headers: { "content-type": "application/x-www-form-urlencoded", accept: "application/json" },
    body: new URLSearchParams(fields).toString(),
  };
}

/** Exchanges the authorization code. Returns the refresh token and the Apple user it belongs to. */
export async function exchangeCode(code: string, config: AppleConfig, clientSecret: string, fetch: Fetch): Promise<{ refreshToken: string; subject: string }> {
  const response = await fetch(APPLE_TOKEN_URL, form({
    client_id: config.bundleID, client_secret: clientSecret, code, grant_type: "authorization_code",
  }));
  if (response.status === 400) {
    // invalid_grant: expired, already used, or issued to another app. The app asks for a fresh one.
    throw new RevokeError(400, "invalid_authorization_code", "Sign in with Apple again, then retry.");
  }
  if (!response.ok) throw new RevokeError(502, "apple_unavailable", "Apple couldn't be reached. Nothing was deleted; try again.");
  const body = await response.json().catch(() => ({})) as { refresh_token?: unknown; id_token?: unknown };
  if (typeof body.refresh_token !== "string" || typeof body.id_token !== "string") {
    throw new RevokeError(502, "apple_unavailable", "Apple couldn't be reached. Nothing was deleted; try again.");
  }
  // Received directly from Apple over TLS; only its subject is needed.
  let subject: unknown;
  try { subject = decodeJwt(body.id_token).sub; } catch { subject = undefined; }
  if (typeof subject !== "string") throw new RevokeError(502, "apple_unavailable", "Apple couldn't be reached. Nothing was deleted; try again.");
  return { refreshToken: body.refresh_token, subject };
}

export async function revokeRefreshToken(refreshToken: string, config: AppleConfig, clientSecret: string, fetch: Fetch): Promise<void> {
  const response = await fetch(APPLE_REVOKE_URL, form({
    client_id: config.bundleID, client_secret: clientSecret, token: refreshToken, token_type_hint: "refresh_token",
  }));
  if (!response.ok) throw new RevokeError(502, "apple_unavailable", "Apple couldn't be reached. Nothing was deleted; try again.");
}
