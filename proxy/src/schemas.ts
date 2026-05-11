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

// ---------------------------------------------------------------------------
// /dynamic-line — short reactive lines fired in-run by the ContextualCoach
// ---------------------------------------------------------------------------

export const DynamicLineRequestSchema = z.object({
    personalityId: z.string().default("roast_coach"),
    trigger: z.enum([
        "hr_spike",
        "pace_drop",
        "pace_surge",
        "quiet_stretch",
        "custom",
    ]),
    runContext: z.object({
        elapsedSeconds: z.number().nonnegative(),
        distanceMeters: z.number().nonnegative(),
        currentHR: z.number().positive().optional(),
        avgHR: z.number().positive().optional(),
        currentPaceSecPerKm: z.number().positive().optional(),
        avgPaceSecPerKm: z.number().positive().optional(),
        planKind: z.enum(["distance", "time", "open"]),
        planDistanceKm: z.number().positive().optional(),
        planTimeMinutes: z.number().positive().optional(),
        runType: z.enum(["outdoor", "treadmill"]),
    }),
    recentDispatched: z.array(z.string().min(1).max(500)).max(10).optional(),
    customNote: z.string().max(300).optional(),
});

export type DynamicLineRequest = z.infer<typeof DynamicLineRequestSchema>;

export const DynamicLineModelOutputSchema = z.object({
    text: z.string().min(1).max(500),
});

export interface DynamicLineResponse {
    text: string;
    model: string;
}

// ---------------------------------------------------------------------------
// /music-comment — DJ commentary about the currently-playing track
// ---------------------------------------------------------------------------

export const MusicCommentRequestSchema = z.object({
    personalityId: z.string().default("roast_coach"),
    track: z
        .object({
            title: z.string().min(1).max(200).optional(),
            artist: z.string().min(1).max(200).optional(),
            album: z.string().min(1).max(200).optional(),
            isPlaying: z.boolean().optional(),
        })
        .optional(),
    /// True when audio is detected but we don't have track metadata
    /// (e.g. Spotify isn't connected yet). The coach riffs generically.
    /// Note: client-side now suppresses music_riff entirely when no
    /// lyric is available, so this branch is reachable only via the
    /// CoachPlayground tester / API consumers.
    unknownAudio: z.boolean().default(false),
    /// The single lyric line being sung right now. If present, this is
    /// what the DJ comments on — primary subject, not the track metadata.
    currentLyric: z.string().min(1).max(500).optional(),
    /// 1-3 surrounding lines so the model knows the flow.
    lyricContext: z.array(z.string().min(1).max(500)).max(8).optional(),
    /// "en" | "zh" — language of the lyric. Other languages are
    /// filtered out client-side.
    lyricLanguage: z.enum(["en", "zh"]).optional(),
    runContext: z.object({
        elapsedSeconds: z.number().nonnegative(),
        distanceMeters: z.number().nonnegative(),
        currentHR: z.number().positive().optional(),
        currentPaceSecPerKm: z.number().positive().optional(),
        planKind: z.enum(["distance", "time", "open"]),
        runType: z.enum(["outdoor", "treadmill"]),
    }),
    recentDispatched: z.array(z.string().min(1).max(500)).max(10).optional(),
});

export type MusicCommentRequest = z.infer<typeof MusicCommentRequestSchema>;

export const MusicCommentModelOutputSchema = z.object({
    text: z.string().min(1).max(500),
});

export interface MusicCommentResponse {
    text: string;
    model: string;
}
