import react from "@vitejs/plugin-react";
import { defineConfig } from "vite";

export default defineConfig({
  plugins: [react()],
  server: {
    // Allow the shared/ folder (outside web/) to be served in dev.
    fs: { allow: [".."] },
  },
});
