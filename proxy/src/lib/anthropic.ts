/**
 * Thin wrapper around Anthropic's Messages API. The Worker is the only
 * place the API key lives; the iOS app talks to the Worker, never to
 * Anthropic directly.
 *
 * Uses prompt caching on the system prompt so repeated calls during a
 * session keep cost low — the personality prompt is stable, the user
 * prompt varies.
 */

const ANTHROPIC_VERSION = "2023-06-01";
const ANTHROPIC_URL = "https://api.anthropic.com/v1/messages";

export const SCRIPT_MODEL = "claude-sonnet-4-6";
export const REPLY_MODEL = "claude-haiku-4-5-20251001";

export interface AnthropicCallParams {
    apiKey: string;
    model: string;
    systemPrompt: string;
    userPrompt: string;
    maxTokens: number;
    /** Whether to apply prompt caching to the system prompt. */
    cacheSystem?: boolean;
}

export async function callAnthropic(params: AnthropicCallParams): Promise<string> {
    const systemBlock = params.cacheSystem
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
        system: systemBlock,
        messages: [
            {
                role: "user" as const,
                content: params.userPrompt,
            },
        ],
    };

    const response = await fetch(ANTHROPIC_URL, {
        method: "POST",
        headers: {
            "x-api-key": params.apiKey,
            "anthropic-version": ANTHROPIC_VERSION,
            "content-type": "application/json",
        },
        body: JSON.stringify(body),
    });

    if (!response.ok) {
        const errText = await response.text().catch(() => "<no body>");
        throw new AnthropicError(
            `Anthropic ${response.status}: ${errText}`,
            response.status,
        );
    }

    const data = (await response.json()) as AnthropicResponse;
    const text = data.content
        ?.filter((b) => b.type === "text")
        .map((b) => b.text)
        .join("")
        ?.trim();

    if (!text) {
        throw new AnthropicError("Anthropic returned an empty completion", 502);
    }
    return text;
}

interface AnthropicResponse {
    content?: Array<{ type: string; text?: string }>;
    usage?: {
        input_tokens: number;
        output_tokens: number;
        cache_creation_input_tokens?: number;
        cache_read_input_tokens?: number;
    };
}

export class AnthropicError extends Error {
    constructor(
        message: string,
        public readonly httpStatus: number,
    ) {
        super(message);
        this.name = "AnthropicError";
    }
}
