<script setup lang="ts">
// Query results arrive as rows of values; BlessTable wants objects keyed by
// column. Keys are positions, so duplicate column names still work.
import { computed } from "vue";
import { BlessTable } from "blessing-ui";

const props = defineProps<{ columns: string[]; rows: unknown[][]; caption?: string }>();

const columns = computed(() => props.columns.map((label, i) => ({ key: `c${i}`, label })));
const rows = computed(() =>
  props.rows.map((row) => Object.fromEntries(row.map((v, i) => [`c${i}`, show(v)]))),
);

function show(v: unknown): string {
  if (v === null) return "NULL";
  return typeof v === "object" ? JSON.stringify(v) : String(v);
}
</script>

<template>
  <div class="result-table">
    <BlessTable :columns :rows :caption striped />
  </div>
</template>

<style>
.result-table {
  overflow-x: auto;
  font-variant-numeric: tabular-nums;
}
</style>
