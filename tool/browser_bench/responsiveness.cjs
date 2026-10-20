const { chromium } = require("playwright");
const fs = require("fs");
const path = require("path");
const target = "dart";
const origin = process.env.BENCH_ORIGIN || "http://127.0.0.1:18765";
const resultDir = process.env.BENCH_RESULTS || path.join(__dirname, "results");
fs.mkdirSync(resultDir, { recursive: true });
const command = "awk 'BEGIN{s=0;for(i=1;i<=10000;i++)s=(s+i)%1000003;print s}'";
const expected = String(((10000 * 10001) / 2) % 1000003);
const out = {
  target,
  command,
  expected,
  intervalMs: 16,
  date: new Date().toISOString(),
  samples: [],
  errors: [],
  methodology:
    "A main-thread 16 ms interval runs while one guest command executes. Report delay beyond 16 ms; allow one final 32 ms observation period after command. One warmup plus five measured runs. This measures event-loop responsiveness, not visual frame rate.",
};
const save = () =>
  fs.writeFileSync(
    `${resultDir}/${target}-responsiveness.json`,
    JSON.stringify(out, null, 2),
  );
(async () => {
  const browser = await chromium.launch({
    executablePath: "/usr/bin/chromium",
    headless: true,
    args: ["--no-sandbox"],
  });
  try {
    out.browser = browser.version();
    const page = await browser.newPage();
    page.setDefaultTimeout(180000);
    await page.goto(`${origin}/${target}.html`);
    await page.waitForFunction(() => window.ready === true);
    await page.evaluate(() => adapter.boot());
    for (let iteration = -1; iteration < 5; iteration++) {
      const value = await page.evaluate(async (command) => {
        const delays = [];
        let previous = performance.now();
        const timer = setInterval(() => {
          const now = performance.now();
          delays.push(Math.max(0, now - previous - 16));
          previous = now;
        }, 16);
        const start = performance.now();
        try {
          const result = await adapter.exec(command);
          const ms = performance.now() - start;
          await new Promise((resolve) => setTimeout(resolve, 32));
          return { result, ms, delays };
        } finally {
          clearInterval(timer);
        }
      }, command);
      if (
        value.result.exitCode !== 0 ||
        value.result.stdout.trim() !== expected
      )
        throw Error("Output mismatch: " + JSON.stringify(value.result));
      const sorted = [...value.delays].sort((a, b) => a - b);
      if (!sorted.length) throw Error("No timer observations");
      const sample = {
        iteration,
        warmup: iteration === -1,
        ...value,
        maxDelayMs: sorted.at(-1),
        p95DelayMs: sorted[Math.ceil(sorted.length * 0.95) - 1],
      };
      out.samples.push(sample);
      save();
      console.log(
        target,
        "responsiveness",
        iteration,
        "ms",
        value.ms.toFixed(2),
        "max delay",
        sample.maxDelayMs.toFixed(2),
      );
    }
    await page.evaluate(() => adapter.dispose());
  } catch (error) {
    out.errors.push(error.message);
    throw error;
  } finally {
    save();
    await browser.close();
  }
})().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
