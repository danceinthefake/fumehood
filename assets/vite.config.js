import { defineConfig } from "vite";
import vue from "@vitejs/plugin-vue";

// Built into ../priv/static, served by Phoenix. `pnpm dev` runs Vite on
// :5173 and forwards /api and the /socket WebSocket to Phoenix on :4000.
export default defineConfig({
  plugins: [vue()],
  build: { outDir: "../priv/static", emptyOutDir: true },
  server: {
    proxy: {
      "/api": "http://localhost:4000",
      "/socket": { target: "ws://localhost:4000", ws: true },
    },
  },
});
