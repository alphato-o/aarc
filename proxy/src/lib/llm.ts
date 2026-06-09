/**
 * Provider-agnostic dispatcher for LLM calls. Picks Anthropic native
 * or OpenRouter based on which API key is present in the environment.
 * The route handlers don't need to know which provider is in play.
 *
 * Provider (set exactly one key):
 *   OPENROUTER_API_KEY  →  OpenRouter via openai-compatible api
 *   ANTHROPIC_API_KEY   →  Anthropic native /v1/messages
 *
 * Model selection is PER PURPOSE (script / reply / summary), each with a
 * sensible Sonnet default and an optional per-purpose env override, e.g.
 * OPENROUTER_MODEL_REPLY. The legacy bare OPENROUTER_MODEL / ANTHROPIC_MODEL
 * are deliberately NO LONGER consulted: a single global override silently
 * forced every task — scripts, reactive lines, Jessica, music — onto one
 * model and masked the per-purpose defaults. (That's how everything ended
 * up on one reasoning model whose hidden reasoning tokens blew the small
 * reply token budget and truncated the spicier lines.) If a stale
 * OPENROUTER_MODEL secret is still set, it's now harmless — delete it with
 * `wrangler secret delete OPENROUTER_MODEL` to avoid confusion.
 */

import { callAnthropic, AnthropicError } from "./anthropic";
import { callOpenRouter, OpenRouterError } from "./openrouter";

export interface LLMEnv {
    OPENROUTER_API_KEY?: string;
    ANTHROPIC_API_KEY?: string;
    /// Optional per-purpose model overrides (else the Sonnet defaults).
    OPENROUTER_MODEL_SCRIPT?: string;
    OPENROUTER_MODEL_REPLY?: string;
    OPENROUTER_MODEL_SUMMARY?: string;
    ANTHROPIC_MODEL_SCRIPT?: string;
    ANTHROPIC_MODEL_REPLY?: string;
    ANTHROPIC_MODEL_SUMMARY?: string;
    /// Deprecated + ignored — kept only so existing secrets don't trip
    /// type checks. See the note above.
    OPENROUTER_MODEL?: string;
    ANTHROPIC_MODEL?: string;
}

export type Purpose = "script" | "reply" | "summary";

export interface CallParams {
    purpose: Purpose;
    systemPrompt: string;
    userPrompt: string;
    maxTokens: number;
    /** Apply prompt caching to the system block. */
    cacheSystem?: boolean;
}

export interface CallResult {
    text: string;
    /** Echoed back to the client for diagnostic UIs. */
    provider: "openrouter" | "anthropic";
    model: string;
}

// The full run script is PRE-WARMED (generated before the run starts), so
// its latency is absorbed — it runs on the best Anthropic model, Opus 4.8,
// for maximum wit + craft. The in-run reactive lines (reply: Ricky's live
// reactions, Jessica, music) stay on the faster Sonnet 4.5 so they don't
// land stale mid-run.
const DEFAULT_OPENROUTER_MODELS: Record<Purpose, string> = {
    script: "anthropic/claude-opus-4.8",
    reply: "anthropic/claude-sonnet-4.5",
    summary: "anthropic/claude-sonnet-4.5",
};

const DEFAULT_ANTHROPIC_MODELS: Record<Purpose, string> = {
    script: "claude-opus-4-8",
    reply: "claude-sonnet-4-6",
    summary: "claude-sonnet-4-6",
};

export async function callLLM(
    params: CallParams,
    env: LLMEnv,
): Promise<CallResult> {
    if (env.OPENROUTER_API_KEY) {
        const override: Record<Purpose, string | undefined> = {
            script: env.OPENROUTER_MODEL_SCRIPT,
            reply: env.OPENROUTER_MODEL_REPLY,
            summary: env.OPENROUTER_MODEL_SUMMARY,
        };
        const model = override[params.purpose] ?? DEFAULT_OPENROUTER_MODELS[params.purpose];
        const text = await callOpenRouter({
            apiKey: env.OPENROUTER_API_KEY,
            model,
            systemPrompt: params.systemPrompt,
            userPrompt: params.userPrompt,
            maxTokens: params.maxTokens,
            cacheSystem: params.cacheSystem,
            appName: "AARC",
            appUrl: "https://aarun.club",
        });
        return { text, provider: "openrouter", model };
    }

    if (env.ANTHROPIC_API_KEY) {
        const override: Record<Purpose, string | undefined> = {
            script: env.ANTHROPIC_MODEL_SCRIPT,
            reply: env.ANTHROPIC_MODEL_REPLY,
            summary: env.ANTHROPIC_MODEL_SUMMARY,
        };
        const model = override[params.purpose] ?? DEFAULT_ANTHROPIC_MODELS[params.purpose];
        const text = await callAnthropic({
            apiKey: env.ANTHROPIC_API_KEY,
            model,
            systemPrompt: params.systemPrompt,
            userPrompt: params.userPrompt,
            maxTokens: params.maxTokens,
            cacheSystem: params.cacheSystem,
        });
        return { text, provider: "anthropic", model };
    }

    throw new LLMConfigError(
        "no LLM provider configured — set OPENROUTER_API_KEY or ANTHROPIC_API_KEY",
    );
}

export class LLMConfigError extends Error {
    constructor(message: string) {
        super(message);
        this.name = "LLMConfigError";
    }
}

/** Common error-narrowing helper for route handlers. */
export function describeUpstreamError(e: unknown): {
    httpStatus: number;
    message: string;
} {
    if (e instanceof AnthropicError || e instanceof OpenRouterError) {
        return { httpStatus: e.httpStatus, message: e.message };
    }
    if (e instanceof LLMConfigError) {
        return { httpStatus: 500, message: e.message };
    }
    return { httpStatus: 502, message: e instanceof Error ? e.message : String(e) };
}
