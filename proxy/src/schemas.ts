import { z } from "zod";

// ---------------------------------------------------------------------------
// Inbound: what the iOS client posts to /generate-script
// ---------------------------------------------------------------------------

export const GenerateScriptRequestSchema = z.object({
    goal: z.enum(["free", "training", "race"]).default("free"),
    distanceKm: z.number().positive().max(100),
    targetPaceSecPerKm: z.number().positive().optional(),
    personalityId: z.string().default("roast_coach"),
    runType: z.enum(["outdoor", "treadmill"]).default("outdoor"),
    recentRunSummary: z.string().max(500).optional(),
    userMemory: z.array(z.string().max(200)).max(20).optional(),
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
        atMeters: z.number().nonnegative().optional(),
        everyMeters: z.number().positive().optional(),
        remainingMeters: z.number().positive().optional(),
    })
    .superRefine((data, ctx) => {
        switch (data.type) {
            case "time":
                if (data.atSeconds === undefined) {
                    ctx.addIssue({
                        code: z.ZodIssueCode.custom,
                        message: "time triggers require atSeconds",
                    });
                }
                break;
            case "distance":
                if ((data.atMeters === undefined) === (data.everyMeters === undefined)) {
                    ctx.addIssue({
                        code: z.ZodIssueCode.custom,
                        message: "distance triggers require exactly one of atMeters / everyMeters",
                    });
                }
                break;
            case "halfway":
                break;
            case "near_finish":
                if (data.remainingMeters === undefined) {
                    ctx.addIssue({
                        code: z.ZodIssueCode.custom,
                        message: "near_finish triggers require remainingMeters",
                    });
                }
                break;
            case "finish":
                // Fires the moment the runner reaches the planned
                // distance. No parameters needed.
                break;
        }
    });

export const ScriptMessageSchema = z.object({
    id: z.string().min(1).max(64),
    triggerSpec: TriggerSpecSchema,
    text: z.string().min(1).max(280),
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
