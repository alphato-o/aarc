/**
 * OpenRouter adapter. OpenRouter exposes an OpenAI-compatible Chat
 * Completions endpoint that proxies to Anthropic, OpenAI, Google, etc.
 *
 * For Anthropic models we still get prompt caching by putting the
 * system prompt in content blocks with `cache_control: ephemeral`,
 * which OpenRouter passes through.
 *
 * Keys are sk-or-v1-… and are sent via Authorization: Bearer.
 */

const OPENROUTER_URL = "https://openrouter.ai/api/v1/chat/completions";

export interface OpenRouterParams {
    apiKey: string;
    model: string;
    systemPrompt: string;
    userPrompt: string;
    maxTokens: number;
    /** Apply Anthropic-style prompt caching to the system block. */
    cacheSystem?: boolean;
    /** Optional referer/title that show up on openrouter.ai analytics. */
    appUrl?: string;
    appName?: string;
}

export async function callOpenRouter(params: OpenRouterParams): Promise<string> {
    const headers: Record<string, string> = {
        Authorization: `Bearer ${params.apiKey}`,
        "Content-Type": "application/json",
    };
    if (params.appUrl) headers["HTTP-Referer"] = params.appUrl;
    if (params.appName) headers["X-Title"] = params.appName;

    // Use content blocks so we can attach cache_control. OpenRouter
    // accepts both string and array content; the array form is required
    // for prompt caching against Anthropic models.
    const systemContent = params.cacheSystem
        ? [
              {
                  type: "text" as const,
                  text: params.systemPrompt,
                  cache_control: { type: "ephemeral" as const },
              },
          ]
        : [{ type: "text" as const, text: params.systemPrompt }];

    const body = {
        model: params.model,
        max_tokens: params.maxTokens,
        messages: [
            { role: "system" as const, content: systemContent },
            { role: "user" as const, content: params.userPrompt },
        ],
    };

    const response = await fetch(OPENROUTER_URL, {
        method: "POST",
        headers,
        body: JSON.stringify(body),
    });

    if (!response.ok) {
        const errText = await response.text().catch(() => "<no body>");
        throw new OpenRouterError(
            `OpenRouter ${response.status}: ${errText}`,
            response.status,
        );
    }

    const data = (await response.json()) as OpenRouterResponse;
    const content = data.choices?.[0]?.message?.content;
    const text = typeof content === "string"
        ? content.trim()
        : (content ?? [])
              .filter((c) => c.type === "text")
              .map((c) => c.text ?? "")
              .join("")
              .trim();

    if (!text) {
        throw new OpenRouterError(
            "OpenRouter returned an empty completion",
            502,
        );
    }
    return text;
}

interface OpenRouterResponse {
    choices?: Array<{
        message?: {
            role: string;
            content: string | Array<{ type: string; text?: string }>;
        };
    }>;
}

export class OpenRouterError extends Error {
    constructor(
        message: string,
        public readonly httpStatus: number,
    ) {
        super(message);
        this.name = "OpenRouterError";
    }
}
