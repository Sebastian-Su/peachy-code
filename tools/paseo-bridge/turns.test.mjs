import assert from "node:assert/strict";
import test from "node:test";
import { endedTurn, finalReply, finishedWhileAway, isReportable, startedTurn } from "./turns.mjs";

test("a turn ends only on a running to idle or error transition", () => {
  assert.equal(endedTurn("running", { status: "idle" }), true);
  assert.equal(endedTurn("running", { status: "error" }), true);
  assert.equal(endedTurn(undefined, { status: "idle" }), false);
  assert.equal(endedTurn("idle", { status: "idle" }), false);
  assert.equal(endedTurn("running", { status: "closed" }), false);
});

test("delegated children are not reported", () => {
  assert.equal(isReportable({ labels: {} }), true);
  assert.equal(isReportable({ labels: { "paseo.parent-agent-id": "a" } }), false);
});

test("the final reply joins the trailing assistant chunks", () => {
  const item = (type, text) => ({ item: { type, text } });
  assert.equal(finalReply([
    item("user_message", "q"), item("assistant_message", "early"), item("tool_call"),
    item("assistant_message", "Done.\n\n"), item("assistant_message", "| a |"),
  ]), "Done.\n\n| a |");
  assert.equal(finalReply([item("user_message", "q"), item("tool_call")]), null);
  assert.equal(finalReply([]), null);
});

test("a reconnect snapshot reports turns that finished while the link was down", () => {
  const before = Date.parse("2026-11-18T15:03:00Z");
  const agent = (attentionTimestamp, attentionReason = "finished") => ({ status: "idle", attentionReason, attentionTimestamp });
  assert.equal(finishedWhileAway(agent("2026-11-18T15:03:37Z"), before), true);
  assert.equal(finishedWhileAway(agent("2026-11-18T15:02:00Z"), before), false);
  assert.equal(finishedWhileAway(agent("2026-11-18T15:03:37Z", "permission"), before), false);
  assert.equal(finishedWhileAway(agent(null), before), false);
  // The first snapshot after start only seeds state.
  assert.equal(finishedWhileAway(agent("2026-11-18T15:03:37Z"), undefined), false);
});

test("a turn starts when an agent begins running, including one already running at startup", () => {
  assert.equal(startedTurn(undefined, { status: "running" }), true);
  assert.equal(startedTurn("idle", { status: "running" }), true);
  assert.equal(startedTurn("running", { status: "running" }), false);
  assert.equal(startedTurn("idle", { status: "idle" }), false);
});
