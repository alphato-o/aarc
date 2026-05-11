import { z } from "zod";

// ---------------------------------------------------------------------------
// Inbound: what the iOS client posts to /generate-script
// ---------------------------------------------------------------------------

export const GenerateScriptRequestSchema = z
    .object({
        goal: z.enum(["free", "training", "race"]).default("free"),
        planKind: z.enum(["distance", "time", "open"]).default("distance"),
        /// Required when planKind == "distance".
        distanceKm: z.number().positive().max(100).optional(),
        /// Required when planKind == "time". Up to 12 hours.
        timeMinutes: z.number().positive().max(720).optional(),
        personalityId: z.string().default("roast_coach"),
        runType: z.enum(["outdoor", "treadmill"]).default("outdoor"),
        recentRunSummary: z.string().max(500).optional(),
        userMemory: z.array(z.string().max(200)).max(20).optional(),
    })
    .superRefine((data, ctx) => {
        if (data.planKind === "distance" && data.distanceKm === undefined) {
            ctx.addIssue({
                code: z.ZodIssueCode.custom,
                message: "distanceKm is required when planKind == distance",
            });
        }
        if (data.planKind === "time" && data.timeMinutes === undefined) {
            ctx.addIssue({
                code: z.ZodIssueCode.custom,
                message: "timeMinutes is required when planKind == time",
            });
        }
    });

export type GenerateScriptRequest = z.infer<typeof GenerateScriptRequestSchema>;

// ---------------------------------------------------------------------------
// Outbound: what we hand back to the iOS client. Same shape Anthropic
// returns to us, after schema validation. Mirrors AARCKit.TriggerSpec
// and AARCKit.ScriptMessage on the Swift side.
// ---------------------------------------------------------------------------

const TriggerSpecSchema = z
    .object({
        type: z.enum(["time", "distance", "halfway", "near_finish", "finish"]),
        atSeconds: z.number().int().nonnegative().optional(),
        everySeconds: z.number().int().positive().optional(),
        atMeters: z.number().nonnegative().optional(),
        everyMeters: z.number().positive().optional(),
        remainingMeters: z.number().positive().optional(),
        remainingSeconds: z.number().int().positive().optional(),
    })
    .superRefine((data, ctx) => {
        switch (data.type) {
            case "time": {
                const hasAt = data.atSeconds !== undefined;
                const hasEvery = data.everySeconds !== undefined;
                if (hasAt === hasEvery) {
                    ctx.addIssue({
                        code: z.ZodIssueCode.custom,
                        message:
                            "time triggers require exactly one of atSeconds / everySeconds",
                    });
                }
                break;
            }
            case "distance": {
                const hasAt = data.atMeters !== undefined;
                const hasEvery = data.everyMeters !== undefined;
                if (hasAt === hasEvery) {
                    ctx.addIssue({
                        code: z.ZodIssueCode.custom,
                        message:
                            "distance triggers require exactly one of atMeters / everyMeters",
                    });
                }
                break;
            }
            case "halfway":
                break;
            case "near_finish": {
                const hasMeters = data.remainingMeters !== undefined;
                const hasSeconds = data.remainingSeconds !== undefined;
                if (hasMeters === hasSeconds) {
                    ctx.addIssue({
                        code: z.ZodIssueCode.custom,
                        message:
                            "near_finish triggers require exactly one of remainingMeters / remainingSeconds",
                    });
                }
                break;
            }
            case "finish":
                break;
        }
    });

export const ScriptMessageSchema = z.object({
    id: z.string().min(1).max(64),
    triggerSpec: TriggerSpecSchema,
    text: z.string().min(1).max(500),
    /// Additional rotation candidates for looping triggers
    /// (distance.everyMeters, time.everySeconds). ScriptEngine cycles
    /// through [text, *textVariants] so the per-km loop doesn't
    /// repeat itself. Empty/omitted for one-shot messages.
    textVariants: z.array(z.string().min(1).max(500)).max(20).optional(),
    priority: z.number().int().min(0).max(100).default(50),
    playOnce: z.boolean().default(true),
});

export const ScriptSchema = z.array(ScriptMessageSchema).min(2).max(40);

export type ScriptMessage = z.infer<typeof ScriptMessageSchema>;

export interface GenerateScriptResponse {
    scriptId: string;
    model: string;
    messages: ScriptMessage[];
}
