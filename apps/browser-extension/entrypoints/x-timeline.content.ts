import { startXTimelineSync } from "../src/entrypoints/x-timeline";

export default defineContentScript({
  matches: ["https://x.com/*", "https://twitter.com/*"],
  runAt: "document_idle",
  main() {
    startXTimelineSync();
  },
});
