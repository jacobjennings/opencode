import { SessionV1 } from "@opencode-ai/core/v1/session"
import { Database } from "@opencode-ai/core/database/database"
import { LayerNode } from "@opencode-ai/core/effect/layer-node"
import { EventV2Bridge } from "@/event-v2-bridge"
import { expect } from "bun:test"
import { Effect, Layer, Stream } from "effect"
import { Provider } from "@/provider/provider"
import { ProviderV2 } from "@opencode-ai/core/provider"
import { ModelV2 } from "@opencode-ai/core/model"
import { Session } from "@/session/session"
import { LLM } from "../../src/session/llm"
import { MessageV2 } from "../../src/session/message-v2"
import { SessionProcessor } from "../../src/session/processor"
import { MessageID, PartID } from "../../src/session/schema"
import { SessionStatus } from "../../src/session/status"
import { SessionSummary } from "../../src/session/summary"
import { CrossSpawnSpawner } from "@opencode-ai/core/cross-spawn-spawner"
import { SessionProjector } from "@opencode-ai/core/session/projector"
import { LLMEvent } from "@opencode-ai/llm"
import { ProviderError } from "@/provider/error"
import { RuntimeFlags } from "@/effect/runtime-flags"
import { testEffect } from "../lib/effect"
import type { Agent } from "../../src/agent/agent"

const ref = {
  providerID: ProviderV2.ID.make("test"),
  modelID: ModelV2.ID.make("test-model"),
}

function agent(): Agent.Info {
  return {
    name: "build",
    mode: "primary",
    options: {},
    permission: [{ permission: "*", pattern: "*", action: "allow" }],
  }
}

function model(): Provider.Model {
  return {
    id: ref.modelID,
    providerID: ref.providerID,
  } as unknown as Provider.Model
}

const summary = Layer.succeed(
  SessionSummary.Service,
  SessionSummary.Service.of({
    summarize: () => Effect.void,
    diff: () => Effect.succeed([]),
    computeDiff: () => Effect.succeed([]),
  }),
)

let attempts = 0
const textRetryLLM = Layer.succeed(
  LLM.Service,
  LLM.Service.of({
    stream: () => {
      attempts += 1
      if (attempts === 1) {
        return Stream.concat(
          Stream.make(
            LLMEvent.textStart({ id: "text-one" }),
            LLMEvent.textDelta({ id: "text-one", text: "one" }),
            LLMEvent.textEnd({ id: "text-one" }),
          ),
          Stream.fail(new ProviderError.ResponseStreamError("upstream boom")),
        )
      }
      return Stream.make(
        LLMEvent.textStart({ id: "text-two" }),
        LLMEvent.textDelta({ id: "text-two", text: "two" }),
        LLMEvent.textEnd({ id: "text-two" }),
        LLMEvent.finish({ reason: "stop" }),
      )
    },
  }),
)

const root = LayerNode.group([
  SessionProcessor.node,
  Session.node,
  SessionProjector.node,
  Provider.node,
  Database.node,
  EventV2Bridge.node,
  SessionStatus.node,
  CrossSpawnSpawner.node,
])
const replacements = [
  [SessionSummary.node, summary],
  [RuntimeFlags.node, RuntimeFlags.layer({ experimentalEventSystem: true })],
  [LLM.node, textRetryLLM],
] as const
const env = LayerNode.compile(LayerNode.group([root]), replacements)

const it = testEffect(env)

it.instance("session.processor does not duplicate text across a retried attempt", () =>
  Effect.gen(function* () {
    const session = yield* Session.Service
    const processors = yield* SessionProcessor.Service
    const mdl = model()

    const chat = yield* session.create({})
    const parent = yield* session.updateMessage({
      id: MessageID.ascending(),
      role: "user",
      sessionID: chat.id,
      agent: "build",
      model: ref,
      time: { created: Date.now() },
    })
    yield* session.updatePart({
      id: PartID.ascending(),
      messageID: parent.id,
      sessionID: chat.id,
      type: "text",
      text: "tool",
    })
    const msg = yield* session.updateMessage({
      id: MessageID.ascending(),
      role: "assistant",
      sessionID: chat.id,
      mode: "build",
      agent: "build",
      path: { cwd: process.cwd(), root: process.cwd() },
      cost: 0,
      tokens: {
        total: 0,
        input: 0,
        output: 0,
        reasoning: 0,
        cache: { read: 0, write: 0 },
      },
      modelID: ref.modelID,
      providerID: ref.providerID,
      parentID: parent.id,
      time: { created: Date.now() },
      finish: "end_turn",
    })

    const handle = yield* processors.create({
      assistantMessage: msg,
      sessionID: chat.id,
      model: mdl,
    })

    const value = yield* handle.process({
      user: {
        id: parent.id,
        sessionID: chat.id,
        role: "user",
        time: parent.time,
        agent: parent.agent,
        model: { providerID: ref.providerID, modelID: ref.modelID },
      } satisfies SessionV1.User,
      sessionID: chat.id,
      model: mdl,
      agent: agent(),
      system: [],
      messages: [{ role: "user", content: "tool" }],
      tools: {},
    })

    const parts = yield* MessageV2.parts(msg.id)
    const textParts = parts.filter((part) => part.type === "text").map((part) => part.text)
    expect(value).toBe("continue")
    expect(textParts).toEqual(["two"])
  }),
)
