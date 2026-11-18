// Pure helpers shared by the bridge and its tests.

/** A turn ends when an agent we saw running becomes idle or errors. */
export function endedTurn(previousStatus, agent) {
  return previousStatus === "running" && (agent.status === "idle" || agent.status === "error");
}

/**
 * After a reconnect the snapshot is all we get. A turn that finished while the link was down
 * still carries its attention timestamp, which is newer than the previous snapshot.
 */
export function finishedWhileAway(agent, previousSnapshotAt) {
  if (previousSnapshotAt == null || !agent.attentionTimestamp) return false;
  if (agent.attentionReason !== "finished" && agent.attentionReason !== "error") return false;
  return Date.parse(agent.attentionTimestamp) > previousSnapshotAt;
}

/** Children delegated by another agent report to their parent, not to the user. */
export function isReportable(agent) {
  return !agent.labels?.["paseo.parent-agent-id"];
}

/** The final reply is the trailing run of assistant message chunks in the latest turn. */
export function finalReply(entries = []) {
  const chunks = [];
  for (let i = entries.length - 1; i >= 0; i--) {
    const item = entries[i]?.item;
    if (item?.type === "assistant_message") {
      chunks.unshift(item.text ?? "");
    } else if (chunks.length > 0) {
      break;
    }
  }
  const text = chunks.join("").trim();
  return text || null;
}
