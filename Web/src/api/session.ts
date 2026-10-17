import type { AccessScope } from "./types";
import { FiscalApiError } from "./adapter";

/** Read-only scopes the owner panel asks for; staging and commits stay with the Agent. */
export const PANEL_SCOPES: AccessScope[] = ["read:reports", "read:ledger", "export:reports"];

const STORAGE_KEY = "fiscal.panel.session";

type Json = Record<string, unknown>;

const errorCode = (body: unknown): string | undefined => {
  const error = body && typeof body === "object" ? (body as Json).error : undefined;
  return error && typeof error === "object" && typeof (error as Json).code === "string" ? ((error as Json).code as string) : undefined;
};

const friendly: Record<string, string> = {
  invalid_totp: "验证码不正确或已过期，请输入当前的 6 位验证码。",
  totp_reused: "这个验证码刚用过，请等下一个验证码（约 30 秒）。",
  challenge_expired: "登录请求已过期，请重新输入当前验证码。",
  auth_rate_limited: "尝试次数过多，请几分钟后再试。",
  too_many_pending: "待批准的请求太多，请稍后再试。",
};

const errorMessage = (body: unknown, fallback: string): string => {
  const code = errorCode(body);
  if (code && friendly[code]) return friendly[code];
  const error = body && typeof body === "object" ? (body as Json).error : undefined;
  if (error && typeof error === "object" && typeof (error as Json).message === "string") return (error as Json).message as string;
  return fallback;
};

interface PendingLogin {
  challengeId: string;
  pollToken: string;
  expiresAt: number;
}

/**
 * Authenticator login for the owner panel. The short-lived session token lives
 * in sessionStorage only (this tab, cleared when it closes) so a reload does
 * not ask for a new code; it is never put in localStorage, cookies or URLs.
 */
export class PanelSession {
  private memoryToken: string | null = null;
  /** A wrong code retries the same challenge instead of leaving orphans in the approval queue. */
  private pending: PendingLogin | null = null;

  constructor(private readonly authBase: string) {}

  token(): string | null {
    if (this.memoryToken) return this.memoryToken;
    try {
      this.memoryToken = window.sessionStorage.getItem(STORAGE_KEY);
    } catch {
      this.memoryToken = null;
    }
    return this.memoryToken;
  }

  clear(): void {
    this.memoryToken = null;
    try {
      window.sessionStorage.removeItem(STORAGE_KEY);
    } catch {
      // Storage may be unavailable; the in-memory token is already gone.
    }
  }

  private save(token: string): void {
    this.memoryToken = token;
    try {
      window.sessionStorage.setItem(STORAGE_KEY, token);
    } catch {
      // Keep the in-memory token when storage is blocked.
    }
  }

  private async post(path: string, body: Json, extraHeaders: Record<string, string> = {}): Promise<Json> {
    const response = await fetch(`${this.authBase}${path}`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json", ...extraHeaders },
      body: JSON.stringify(body),
    });
    const data = (await response.json().catch(() => ({}))) as Json;
    if (!response.ok) throw new FiscalApiError(errorCode(data) ?? "login_failed", errorMessage(data, `登录失败（${response.status}）。`), response.status);
    return data;
  }

  /** Create, approve and redeem a session challenge in one step with the current code. */
  async login(code: string): Promise<void> {
    if (!/^\d{6}$/.test(code)) throw new FiscalApiError("invalid_totp", "请输入 6 位数字验证码。");
    if (!this.pending || this.pending.expiresAt - Date.now() < 30_000) {
      const challenge = await this.post("/auth/challenges", { kind: "session", client_label: "Fiscal 面板", intent: "查看面板", scopes: PANEL_SCOPES });
      this.pending = {
        challengeId: String(challenge.challenge_id ?? ""),
        pollToken: String(challenge.poll_token ?? ""),
        expiresAt: Date.parse(String(challenge.expires_at ?? "")) || Date.now() + 9 * 60_000,
      };
    }
    const { challengeId, pollToken } = this.pending;
    try {
      await this.post(`/auth/challenges/${encodeURIComponent(challengeId)}/approve`, { totp: code });
    } catch (error) {
      if (error instanceof FiscalApiError && error.code === "challenge_expired") this.pending = null;
      throw error;
    }
    this.pending = null;
    const response = await fetch(`${this.authBase}/auth/challenges/${encodeURIComponent(challengeId)}`, {
      headers: { Accept: "application/json", "X-Fiscal-Poll-Token": pollToken },
    });
    const polled = (await response.json().catch(() => ({}))) as Json;
    const token = typeof polled.session_token === "string" ? polled.session_token : null;
    if (!response.ok || !token) throw new FiscalApiError("login_failed", errorMessage(polled, "没有拿到会话，请重试。"), response.status);
    this.save(token);
  }
}
