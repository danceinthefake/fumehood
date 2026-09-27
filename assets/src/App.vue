<script setup lang="ts">
import { computed, onMounted, onUnmounted, ref, watch } from "vue";
import {
  BlessAlert,
  BlessAlertDialog,
  BlessButton,
  BlessKbd,
  BlessSection,
  BlessSidebarNav,
  BlessStage,
  BlessTable,
  BlessTabs,
  BlessText,
  BlessTextarea,
  BlessToaster,
  useToast,
} from "blessing-ui";
import {
  api,
  type ApiError,
  type Backup,
  type Database,
  type DryRun,
  type Identity,
  type ReadResult,
  type RestorePlan,
} from "./api";
import ResultTable from "./ResultTable.vue";
import AuditPanel from "./AuditPanel.vue";

const toast = useToast();

// -- who and where ------------------------------------------------------------

const me = ref<Identity | null>(null);
const databases = ref<Database[]>([]);
const activeId = ref("");
const db = computed(() => databases.value.find((d) => d.id === activeId.value));
const writable = computed(() => db.value?.mode === "read_write");
const tab = ref("query");

const nav = computed(() =>
  databases.value.map((d) => ({
    label: d.label,
    href: `#${d.id}`,
    meta: d.mode === "read_only" ? "read only" : "read / write",
  })),
);

// The database is in the URL hash (#pg16), so a link opens it directly.
function followHash() {
  const id = location.hash.slice(1);
  activeId.value = databases.value.some((d) => d.id === id) ? id : (databases.value[0]?.id ?? "");
}

onMounted(async () => {
  const [who, dbs] = await Promise.all([api.me(), api.databases()]);
  if (who.ok) me.value = who.data;
  if (dbs.ok) databases.value = dbs.data.databases;
  else error.value = dbs.error;
  followHash();
  window.addEventListener("hashchange", followHash);
});
onUnmounted(() => window.removeEventListener("hashchange", followHash));

// -- query: run, dry run, commit ---------------------------------------------

const sql = ref("");
const running = ref(false);
const runningId = ref<string | null>(null);
const elapsed = ref(0);
let ticker: number | undefined;

// Each run / commit gets an id so it can be cancelled while Postgres works.
function startClock(): string {
  const id = crypto.randomUUID();
  runningId.value = id;
  elapsed.value = 0;
  const t0 = performance.now();
  ticker = window.setInterval(() => (elapsed.value = (performance.now() - t0) / 1000), 100);
  return id;
}

function stopClock() {
  window.clearInterval(ticker);
  runningId.value = null;
}

async function cancel() {
  if (runningId.value) await api.cancel(runningId.value);
}
const error = ref<ApiError | null>(null);
const read = ref<ReadResult | null>(null);
const dryRun = ref<DryRun | null>(null);
const confirmCommit = ref(false);
const committing = ref(false);

function clearResult() {
  error.value = null;
  read.value = null;
  dryRun.value = null;
}

// A dry run belongs to the exact SQL it ran; editing the SQL throws it away,
// so nothing can be committed that wasn't previewed.
watch(sql, () => (dryRun.value = null));
watch(activeId, () => {
  clearResult();
  restorePlan.value = null;
  // read-only databases have no backups tab
  if (!writable.value && tab.value === "backups") tab.value = "query";
  else if (tab.value === "backups") loadBackups();
});

async function run() {
  if (!db.value || !sql.value.trim() || running.value) return;
  running.value = true;
  clearResult();
  const res = await api.run(db.value.id, sql.value, startClock());
  stopClock();
  running.value = false;
  if (!res.ok) error.value = res.error;
  else if (res.data.kind === "read") read.value = res.data;
  else dryRun.value = res.data;
}

async function commit() {
  if (!db.value || !dryRun.value) return;
  committing.value = true;
  confirmCommit.value = false; // close the dialog so Cancel is reachable while it runs
  const res = await api.commit(db.value.id, sql.value, dryRun.value, startClock());
  stopClock();
  committing.value = false;
  confirmCommit.value = false;
  if (res.ok) {
    dryRun.value = null;
    toast.success({
      title: `Committed ${res.data.count} ${rows(res.data.count)}`,
      description: `Backup ${res.data.backup_id}`,
    });
  } else {
    dryRun.value = null;
    error.value = res.error;
  }
}

function onKey(e: KeyboardEvent) {
  if (e.key === "Enter" && (e.ctrlKey || e.metaKey)) {
    e.preventDefault();
    run();
  }
}

// -- backups: list and restore ------------------------------------------------

const backups = ref<Backup[]>([]);
const restoring = ref<Backup | null>(null);
const restorePlan = ref<RestorePlan | null>(null);
const confirmRestore = ref(false);

const backupColumns = [
  { key: "taken_at", label: "Taken" },
  { key: "user", label: "By" },
  { key: "operation", label: "Change" },
  { key: "table", label: "Table" },
  { key: "rows", label: "Rows", align: "right" as const },
  { key: "statement", label: "Statement" },
  { key: "actions", label: "" },
];

watch(tab, (t) => t === "backups" && loadBackups());

async function loadBackups() {
  if (!db.value) return;
  const res = await api.backups(db.value.id);
  if (res.ok) backups.value = res.data.backups;
  else error.value = res.error;
}

async function planRestore(backup: Backup) {
  if (!db.value) return;
  error.value = null;
  restoring.value = backup;
  const res = await api.restore(db.value.id, backup.id);
  if (res.ok) restorePlan.value = res.data;
  else {
    restorePlan.value = null;
    error.value = res.error;
  }
}

async function restore() {
  if (!db.value || !restoring.value || !restorePlan.value) return;
  committing.value = true;
  const res = await api.restoreCommit(db.value.id, restoring.value.id, restorePlan.value);
  committing.value = false;
  confirmRestore.value = false;
  restorePlan.value = null;
  if (res.ok) {
    toast.success({
      title: `Restored ${res.data.count} ${rows(res.data.count)}`,
      description: `The restore was backed up too: ${res.data.backup_id}`,
    });
    loadBackups();
  } else error.value = res.error;
}

const rows = (n: number) => (n === 1 ? "row" : "rows");
const when = (iso: string) => new Date(iso).toLocaleString();
</script>

<template>
  <BlessStage>
    <template #sidebar>
      <BlessText as="p" size="lg" weight="bold" class="brand">fumehood</BlessText>
      <BlessSidebarNav :items="nav" :active="`#${activeId}`" label="Databases" />
      <BlessText v-if="me" as="p" size="xs" muted class="who">
        {{ me.id }}<br />via {{ me.source.replace("_", " ") }}
      </BlessText>
    </template>

    <BlessSection
      v-if="db"
      :title="db.label"
      :subtitle="writable ? 'read / write — writes are dry-run first' : 'read only'"
      :watermark="db.id"
    >
      <BlessTabs
        v-model="tab"
        :tabs="[
          { value: 'query', label: 'Query' },
          { value: 'backups', label: 'Backups', disabled: !writable },
          { value: 'audit', label: 'Audit' },
        ]"
        label="View"
      />

      <!-- Query ---------------------------------------------------------------->
      <div v-if="tab === 'query'" class="panel">
        <div @keydown="onKey">
          <BlessTextarea
            v-model="sql"
            :rows="6"
            autogrow
            class="sql"
            placeholder="SELECT * FROM orders WHERE id = 42"
            aria-label="SQL"
          />
        </div>
        <div class="actions">
          <BlessButton color="accent" :loading="running" :disabled="!sql.trim()" @click="run">
            {{ writable ? "Run / dry run" : "Run" }}
          </BlessButton>
          <BlessText size="xs" muted><BlessKbd :keys="['Ctrl', 'Enter']" /></BlessText>
          <template v-if="runningId">
            <BlessText size="sm" muted class="elapsed"
              >running {{ elapsed.toFixed(1) }} s</BlessText
            >
            <BlessButton size="sm" variant="outline" color="danger" @click="cancel">
              Cancel
            </BlessButton>
          </template>
        </div>

        <BlessAlert v-if="error" color="danger" :title="error.rule.replaceAll('_', ' ')">
          {{ error.message }}
        </BlessAlert>

        <template v-if="read">
          <ResultTable
            :columns="read.columns"
            :rows="read.rows"
            :caption="`${read.rows.length} ${rows(read.rows.length)}${read.truncated ? ' — showing the first rows only' : ''}`"
          />
        </template>

        <template v-if="dryRun">
          <BlessAlert color="warning" title="Dry run — nothing has changed yet">
            This {{ dryRun.command.toUpperCase() }} would change
            <strong>{{ dryRun.count }} {{ rows(dryRun.count) }}</strong> in
            <code>{{ dryRun.table }}</code
            >. Committing backs those rows up first.
          </BlessAlert>
          <BlessAlert
            v-if="dryRun.warnings.length"
            color="danger"
            title="Also changes other rows — not backed up"
          >
            <ul class="warnings">
              <li v-for="w in dryRun.warnings" :key="w">{{ w }}</li>
            </ul>
          </BlessAlert>
          <div class="actions">
            <BlessButton
              color="danger"
              :disabled="dryRun.count === 0"
              @click="confirmCommit = true"
            >
              Commit {{ dryRun.count }} {{ rows(dryRun.count) }}
            </BlessButton>
            <BlessButton variant="ghost" @click="dryRun = null">Discard</BlessButton>
          </div>
          <ResultTable
            v-if="dryRun.preview.length"
            :columns="dryRun.columns"
            :rows="dryRun.preview"
            :caption="`After the change (first ${dryRun.preview.length})`"
          />
        </template>
      </div>

      <!-- Audit ------------------------------------------------------------------>
      <div v-else-if="tab === 'audit'" class="panel">
        <AuditPanel :db="db.id" />
      </div>

      <!-- Backups -------------------------------------------------------------->
      <div v-else class="panel">
        <BlessAlert v-if="error" color="danger" :title="error.rule.replaceAll('_', ' ')">
          {{ error.message }}
        </BlessAlert>

        <template v-if="restorePlan && restoring">
          <BlessAlert color="warning" title="Restore dry run — nothing has changed yet">
            Undoing backup <code>{{ restoring.id }}</code> changes
            <strong>{{ restorePlan.count }} {{ rows(restorePlan.count) }}</strong> with:
            <pre class="restore-sql">{{ restorePlan.sql }}</pre>
          </BlessAlert>
          <BlessAlert
            v-if="restorePlan.warnings.length"
            color="danger"
            title="Also changes other rows — not backed up"
          >
            <ul class="warnings">
              <li v-for="w in restorePlan.warnings" :key="w">{{ w }}</li>
            </ul>
          </BlessAlert>
          <div class="actions">
            <BlessButton color="danger" @click="confirmRestore = true">
              Restore {{ restorePlan.count }} {{ rows(restorePlan.count) }}
            </BlessButton>
            <BlessButton variant="ghost" @click="restorePlan = null">Cancel</BlessButton>
          </div>
        </template>

        <BlessText v-if="!backups.length" as="p" muted>No backups yet.</BlessText>
        <div v-else class="result-table">
          <BlessTable :columns="backupColumns" :rows="backups" row-key="id" striped>
            <template #cell-taken_at="{ value }">{{ when(value as string) }}</template>
            <template #cell-operation="{ row }">
              {{ row.operation }}<span v-if="row.restore_of"> (restore)</span>
            </template>
            <template #cell-statement="{ value }"
              ><code>{{ value }}</code></template
            >
            <template #cell-actions="{ row }">
              <BlessButton size="sm" variant="outline" @click="planRestore(row as Backup)">
                Restore
              </BlessButton>
            </template>
          </BlessTable>
        </div>
      </div>
    </BlessSection>

    <BlessAlert v-else-if="error" color="danger" :title="error.rule">{{
      error.message
    }}</BlessAlert>
  </BlessStage>

  <BlessAlertDialog
    v-if="dryRun"
    v-model="confirmCommit"
    :title="`Commit ${dryRun.count} ${rows(dryRun.count)}?`"
    description="The rows are backed up before they change. If the data changed since the dry run, nothing is committed."
    confirm-label="Commit"
    color="danger"
    :loading="committing"
    @confirm="commit"
  />

  <BlessAlertDialog
    v-if="restorePlan"
    v-model="confirmRestore"
    :title="`Restore ${restorePlan.count} ${rows(restorePlan.count)}?`"
    description="The current rows are backed up first, so this restore can be undone too."
    confirm-label="Restore"
    color="danger"
    :loading="committing"
    @confirm="restore"
  />

  <BlessToaster />
</template>

<style>
.brand {
  margin: 0 0 var(--bless-space-6);
  letter-spacing: var(--bless-tracking-wide);
}
.who {
  margin-top: var(--bless-space-8);
  word-break: break-all;
}
.panel {
  display: grid;
  gap: var(--bless-space-4);
  margin-top: var(--bless-space-6);
}
.actions {
  display: flex;
  align-items: center;
  gap: var(--bless-space-3);
}
.sql,
.sql textarea {
  font-family: ui-monospace, "SFMono-Regular", Menlo, monospace;
}
.elapsed {
  font-variant-numeric: tabular-nums;
}
.warnings {
  margin: 0;
  padding-left: var(--bless-space-5);
}
.restore-sql {
  margin: var(--bless-space-2) 0 0;
  white-space: pre-wrap;
  font-size: var(--bless-text-xs);
}
</style>
