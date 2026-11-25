// Streams turn completions of agents on hosts connected to the local Paseo daemon to
// PeachyPet. Output is one JSON object per stdout line; diagnostics go to stderr.
// Local agents are skipped: PeachyPet already receives their hooks directly.
import { createPaseoClient } from "@getpaseo/client";
import { endedTurn, finalReply, finishedWhileAway, isReportable, pendingInput, startedTurn } from "./turns.mjs";

const url = process.env.PASEO_URL || "ws://127.0.0.1:6767/ws";
const HOST_SYNC_MS = 30_000;
const CONNECT_RETRY_MS = 10_000;

const statuses = new Map(); // "serverId/agentId" -> last seen status
const reported = new Map(); // "serverId/agentId" -> when its last turn end was reported (ms)
const waiting = new Map(); // "serverId/agentId" -> id of the prompt it waits on
const watches = new Map(); // serverId -> { release }

const emit = (message) => process.stdout.write(`${JSON.stringify(message)}\n`);
const log = (message) => process.stderr.write(`[paseo-bridge] ${message}\n`);
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));

// PeachyPet holds our stdin open; exit with it so a crashed app leaves no orphan.
process.stdin.on("end", () => process.exit(0));
process.stdin.resume();

function describe(type, host, agent) {
  return {
    type,
    serverId: host.serverId,
    host: host.label,
    agentId: agent.id,
    provider: agent.provider,
    title: agent.title ?? null,
    cwd: agent.cwd ?? null,
    status: agent.status,
  };
}

async function report(remote, host, agent) {
  let lastMessage = null;
  try {
    const page = await remote.agents.ref(agent.id).timeline.refetch({
      direction: "tail", limit: 1, wholeTurns: true, projection: "canonical",
    });
    lastMessage = finalReply(page.entries);
  } catch (error) {
    log(`timeline ${host.label}/${agent.id}: ${error?.message ?? error}`);
  }
  emit({ ...describe("turn_ended", host, agent), lastMessage });
}

async function watch(client, host) {
  const remote = await client.hosts.client(host.serverId);
  const observe = (agent, previousSnapshotAt) => {
    const key = `${host.serverId}/${agent.id}`;
    const previous = statuses.get(key);
    statuses.set(key, agent.status);
    if (startedTurn(previous, agent) && isReportable(agent)) emit(describe("turn_started", host, agent));
    const input = agent.status === "running" ? pendingInput(agent) : null;
    const waitedOn = waiting.get(key);
    if (input) waiting.set(key, input.id); else waiting.delete(key);
    if (isReportable(agent) && input && input.id !== waitedOn) {
      emit({ ...describe("input_needed", host, agent), question: input.text });
    } else if (isReportable(agent) && !input && waitedOn && agent.status === "running") {
      // Answered and still working: back to running.
      emit(describe("turn_started", host, agent));
    }
    const since = previousSnapshotAt == null ? undefined : Math.max(previousSnapshotAt, reported.get(key) ?? 0);
    if (!(endedTurn(previous, agent) || finishedWhileAway(agent, since)) || !isReportable(agent)) return;
    reported.set(key, Date.now());
    void report(remote, host, agent);
  };
  const directory = await remote.agents.list({ filter: { includeArchived: false }, subscribe: {} });
  let snapshotAt = Date.now();
  for (const { agent } of directory.entries) observe(agent);
  directory.subscription.subscribe({
    // Delivered again after the host link reconnects; the SDK restores the observation.
    snapshot({ entries }) {
      const previousSnapshotAt = snapshotAt;
      snapshotAt = Date.now();
      for (const { agent } of entries) observe(agent, previousSnapshotAt);
    },
    update(message) {
      if (message.type === "agent_update" && message.payload.kind === "upsert") observe(message.payload.agent);
    },
  });
  return {
    async release() {
      await directory.subscription.release().catch(() => {});
      await remote.dispose().catch(() => {});
    },
  };
}

async function syncHosts(client, selfId) {
  const { hosts } = await client.hosts.list();
  const remotes = hosts.filter((host) => host.serverId && host.serverId !== selfId);
  for (const host of remotes) {
    // A watch survives a host going offline: its observation restores with a new snapshot.
    if (!host.enabled || host.status !== "online" || watches.has(host.serverId)) continue;
    try {
      watches.set(host.serverId, await watch(client, host));
    } catch (error) {
      log(`watch ${host.label}: ${error?.message ?? error}`);
    }
  }
  for (const [serverId, current] of watches) {
    if (remotes.some((host) => host.serverId === serverId && host.enabled)) continue;
    watches.delete(serverId);
    await current.release();
  }
  emit({
    type: "hosts",
    hosts: remotes.map((host) => ({ label: host.label, status: host.status, watching: watches.has(host.serverId) })),
  });
}

async function connect() {
  for (;;) {
    const client = createPaseoClient({ url });
    try {
      await client.connect();
      return client;
    } catch (error) {
      emit({ type: "disconnected", reason: String(error?.message ?? error) });
      await client.close().catch(() => {});
      await sleep(CONNECT_RETRY_MS);
    }
  }
}

const client = await connect();
const { self } = await client.hosts.list();
emit({ type: "connected", serverId: self.serverId });
for (;;) {
  await syncHosts(client, self.serverId).catch((error) => log(`hosts: ${error?.message ?? error}`));
  await sleep(HOST_SYNC_MS);
}
