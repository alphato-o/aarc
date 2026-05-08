/**
 * Provider-agnostic dispatcher for LLM calls. Picks Anthropic native
 * or OpenRouter based on which API key is present in the environment.
 * The route handlers don't need to know which provider is in play.
 *
 * Env precedence (set exactly one):
 *   OPENROUTER_API_KEY  →  OpenRouter via openai-compatible api
 *   ANTHROPIC_API_KEY   →  Anthropic native /v1/messages
 *
 * Optional overrides:
 *   OPENROUTER_MODEL  (default: "anthropic/claude-sonnet-4.5")
 *   ANTHROPIC_MODEL   (default: "claude-sonnet-4-6")
 */

import { callAnthropic, AnthropicError } from "./anthropic";
import { callOpenRouter, OpenRouterError } from "./openrouter";

export interface LLMEnv {
    OPENROUTER_API_KEY?: string;
    OPENROUTER_MODEL?: string;
    ANTHROPIC_API_KEY?: string;
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

const DEFAULT_OPENROUTER_MODELS: Record<Purpose, string> = {
    script: "anthropic/claude-sonnet-4.5",
    reply: "anthropic/claude-haiku-4.5",
    summary: "anthropic/claude-sonnet-4.5",
};

const DEFAULT_ANTHROPIC_MODELS: Record<Purpose, string> = {
    script: "claude-sonnet-4-6",
    reply: "claude-haiku-4-5-20251001",
    summary: "claude-sonnet-4-6",
};

export async function callLLM(
    params: CallParams,
    env: LLMEnv,
): Promise<CallResult> {
    if (env.OPENROUTER_API_KEY) {
        const model = env.OPENROUTER_MODEL ?? DEFAULT_OPENROUTER_MODELS[params.purpose];
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
        const model = env.ANTHROPIC_MODEL ?? DEFAULT_ANTHROPIC_MODELS[params.purpose];
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
