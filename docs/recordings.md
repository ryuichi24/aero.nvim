# Browser test recordings

The mobile companion shows a **Recordings** section above each session's
transcript. Local `.webm` and `.mp4` links and resource attachments open in an
in-app player with play/pause, seeking, and the browser's fullscreen controls.

Ask your agent to record its browser test and post a Markdown link to the
finalized video. Recording must start before the browser test. Playwright saves
the video when the recorded browser context closes; the companion does not
automatically turn screenshot-only tests into videos.

For example, with Playwright:

```js
const context = await browser.newContext({
  viewport: { width: 390, height: 844 },
  recordVideo: {
    dir: '/absolute/project/.playwright-mcp/recordings',
    size: { width: 390, height: 844 },
  },
});
const page = await context.newPage();
await page.goto('http://localhost:3000');
// Exercise the feature here.
const video = page.video();
await context.close();
await video.saveAs('/absolute/project/.playwright-mcp/feature-demo.webm');
```

The agent should then share `[Feature demo](.playwright-mcp/feature-demo.webm)`.
Use a unique filename for each recording: saved recordings are immutable copies.
The browser must support the video's codec; WebM from Playwright works in current
Chromium browsers, while MP4/H.264 is useful for broader mobile compatibility.

## Retention

When this session is opened in the companion, discovered recordings are copied
to a private `recordings/` directory next to the companion's device credential
file. Entries show **Saved for later** only after that copy succeeds. They then
survive deletion of the original temporary video and companion restarts.

There is no automatic expiration. Remove files from that directory to reclaim
space. Recordings must be finalized, regular WebM or MP4 files under 256 MiB.
The list comes from saved session history, and playback requires a paired device
and an available session in Neovim. Byte-range requests support seeking without
downloading the entire video. Files outside a session's worktree must be
explicitly referenced in its transcript.
