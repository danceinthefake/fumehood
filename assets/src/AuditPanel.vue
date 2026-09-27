<script setup lang="ts">
// Live audit feed of one database: the latest entries when it opens, then
// every new entry the moment the server writes it (Phoenix Channel
// "audit:<db>").
import { onUnmounted, ref, watch } from "vue";
import type { Channel } from "phoenix";
import { BlessTable, BlessText } from "blessing-ui";
import { socket } from "./socket";

export type AuditEntry = {
  id: number;
  at: string;
  user: string;
  source: string;
  action: string;
  sql: string | null;
  outcome: string;
  rule: string | null;
  message: string | null;
  rows: number | null;
  duration_ms: number | null;
  backup_id: string | null;
  restore_of: string | null;
};

const props = defineProps<{ db: string }>();

const entries = ref<AuditEntry[]>([]);
const live = ref(false);
let channel: Channel | null = null;

const columns = [
  { key: "at", label: "When" },
  { key: "user", label: "Who" },
  { key: "action", label: "Action" },
  { key: "outcome", label: "Outcome" },
  { key: "rows", label: "Rows", align: "right" as const },
  { key: "sql", label: "Statement" },
  { key: "duration_ms", label: "ms", align: "right" as const },
];

function join(db: string) {
  channel?.leave();
  entries.value = [];
  live.value = false;
  channel = socket.channel(`audit:${db}`);
  channel.on("entry", (entry: AuditEntry) => {
    entries.value = [entry, ...entries.value].slice(0, 200);
  });
  channel
    .join()
    .receive("ok", (reply: { entries: AuditEntry[] }) => {
      entries.value = reply.entries;
      live.value = true;
    })
    .receive("error", () => (live.value = false));
  channel.onError(() => (live.value = false));
}

watch(() => props.db, join, { immediate: true });
onUnmounted(() => channel?.leave());

const when = (iso: string) => new Date(iso).toLocaleString();
const label = (a: string) => a.replaceAll("_", " ");
</script>

<template>
  <div class="audit">
    <BlessText size="xs" muted :class="live ? 'audit__live' : 'audit__offline'">
      {{ live ? "● live" : "○ connecting…" }}
    </BlessText>
    <BlessText v-if="!entries.length" as="p" muted>Nothing recorded yet.</BlessText>
    <div v-else class="result-table">
      <BlessTable :columns :rows="entries" row-key="id" striped>
        <template #cell-at="{ value }">{{ when(value as string) }}</template>
        <template #cell-action="{ value }">{{ label(value as string) }}</template>
        <template #cell-outcome="{ row }">
          <span :class="`audit__outcome audit__outcome--${row.outcome}`">{{ row.outcome }}</span>
          <span
            v-if="row.rule && row.outcome !== 'ok' && row.rule !== row.outcome"
            class="audit__rule"
          >
            {{ label(row.rule as string) }}</span
          >
        </template>
        <template #cell-sql="{ value }"
          ><code>{{ value }}</code></template
        >
      </BlessTable>
    </div>
  </div>
</template>

<style>
.audit {
  display: grid;
  gap: var(--bless-space-3);
}
.audit__live {
  color: var(--bless-color-success);
}
.audit__outcome--blocked,
.audit__outcome--error {
  color: var(--bless-color-danger);
}
.audit__outcome--cancelled,
.audit__outcome--started {
  color: var(--bless-color-warning);
}
.audit__rule {
  display: block;
  font-size: var(--bless-text-xs);
  color: var(--bless-color-text-muted);
}
</style>
