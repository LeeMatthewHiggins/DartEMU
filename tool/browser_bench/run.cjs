const { chromium } = require("playwright");
const fs = require("fs");
const crypto = require("crypto");
const path = require("path");
const target = "dart",
  origin = process.env.BENCH_ORIGIN || "http://127.0.0.1:18765";
const resultDir = process.env.BENCH_RESULTS || path.join(__dirname, "results");
fs.mkdirSync(resultDir, { recursive: true });
const workloads = [
  [
    "cpu",
    `awk 'BEGIN{s=0;for(i=1;i<=100000;i++)s=(s+i)%1000003;print s}'`,
    "35000",
  ],
  [
    "write",
    `dd if=/dev/zero of=/tmp/payload bs=1024 count=1024 2>/dev/null && wc -c < /tmp/payload`,
    "1048576",
  ],
  [
    "read_hash",
    `sha256sum /tmp/payload`,
    "30e14955ebf1352266dc2ff8067e68104607e750abb9d3b36582b8af909fcb58",
  ],
  [
    "create_files",
    `mkdir -p /tmp/benchfiles; i=0; while [ $i -lt 100 ]; do echo record-$i > /tmp/benchfiles/$i; i=$((i+1)); done; cat /tmp/benchfiles/* | wc -l`,
    "100",
  ],
  [
    "shell_output",
    `awk 'BEGIN{for(i=1000;i>0;i--)print i%100}' | sort -n | uniq -c > /tmp/output.txt; wc -l < /tmp/output.txt`,
    "100",
  ],
];
(async () => {
  const browser = await chromium.launch({
    executablePath: "/usr/bin/chromium",
    headless: true,
    args: ["--no-sandbox"],
  });
  const context = await browser.newContext({ acceptDownloads: true });
  let page;
  const out = {
    target,
    browser: browser.version(),
    date: new Date().toISOString(),
    workloads,
    samples: [],
    errors: [],
    environment: fs.readFileSync(
      path.join(__dirname, "environment.txt"),
      "utf8",
    ),
  };
  const save = () =>
    fs.writeFileSync(
      `${resultDir}/${target}.json`,
      JSON.stringify(out, null, 2),
    );
  async function open() {
    page = await context.newPage();
    page.setDefaultTimeout(180000);
    page.on("pageerror", (e) => out.errors.push(e.message));
    const cdp = await context.newCDPSession(page);
    await cdp.send("Network.enable");
    await cdp.send("Network.setCacheDisabled", { cacheDisabled: true });
    const t = performance.now();
    await page.goto(origin + "/" + target + ".html");
    await page.waitForFunction(() => window.ready === true);
    out.lastLoadMs = performance.now() - t;
  }
  async function timed(name, iteration, fn, verify) {
    const t = performance.now();
    try {
      const value = await fn();
      const ms = performance.now() - t;
      if (verify && !verify(value))
        throw Error("Output mismatch " + JSON.stringify(value).slice(0, 500));
      out.samples.push({
        name,
        iteration,
        warmup: iteration === -1,
        ms,
        value,
      });
      console.log(target, name, iteration, ms.toFixed(2));
      save();
      return value;
    } catch (e) {
      out.samples.push({
        name,
        iteration,
        warmup: iteration === -1,
        error: e.message,
      });
      save();
      throw e;
    }
  }
  try {
    for (let i = -1; i < 5; i++) {
      await open();
      const loadMs = out.lastLoadMs;
      await timed("cold_boot", i, () => page.evaluate(() => adapter.boot()));
      out.samples.push({
        name: "cold_page_to_shell",
        iteration: i,
        warmup: i === -1,
        ms: loadMs + out.samples.at(-1).ms,
      });
      out.resources = await page.evaluate(() =>
        performance
          .getEntriesByType("resource")
          .map((r) => ({
            name: r.name.split("/").pop(),
            duration: r.duration,
            transferSize: r.transferSize,
            decodedBodySize: r.decodedBodySize,
          })),
      );
      if (i < 4) await page.close();
    }
    out.guest = await page.evaluate(() =>
      adapter.exec(
        "uname -a; busybox | head -1; cat /proc/meminfo | head -5; command -v cc; mount",
      ),
    );
    for (const [name, cmd, expected] of workloads) {
      for (let i = -1; i < 5; i++)
        await timed(
          name,
          i,
          () => page.evaluate((c) => adapter.exec(c), cmd),
          (r) =>
            r.exitCode === 0 &&
            (name === "read_hash"
              ? r.stdout.trim().split(/\s+/)[0] === expected
              : r.stdout.trim() === expected),
        );
    }
    out.memory = await page.evaluate(async () => ({
      guest: await adapter.exec("cat /proc/meminfo | head -5"),
      adapter: adapter.memory ? adapter.memory() : null,
      jsHeap: performance.memory
        ? {
            used: performance.memory.usedJSHeapSize,
            total: performance.memory.totalJSHeapSize,
          }
        : null,
    }));
    out.snapshotBytes = await page.evaluate(() => adapter.snapshot());
    for (let i = -1; i < 5; i++)
      await timed(
        "snapshot_resume",
        i,
        () => page.evaluate(() => adapter.resume()),
        (r) => r.exitCode === 0 && r.stdout.trim() === "RESUMED",
      );
    // Export the actual guest output through base64. Check every download against its guest bytes.
    for (let i = -1; i < 5; i++)
      await timed("export", i, async () => {
        const r = await page.evaluate(() =>
          adapter.exec("base64 /tmp/output.txt"),
        );
        if (r.exitCode) throw Error("base64 failed");
        const bytes = Buffer.from(r.stdout.trim(), "base64");
        const rows = bytes.toString().trim().split("\n");
        if (
          rows.length !== 100 ||
          rows.some((r, n) => r.trim().split(/\s+/).join(" ") !== `10 ${n}`)
        )
          throw Error("wrong output content");
        const dl = page.waitForEvent("download");
        await page.evaluate((b64) => {
          const a = document.createElement("a");
          a.href = URL.createObjectURL(
            new Blob([Uint8Array.from(atob(b64), (c) => c.charCodeAt(0))]),
          );
          a.download = "output.txt";
          a.click();
        }, bytes.toString("base64"));
        const d = await dl;
        const p = await d.path();
        const actual = fs.readFileSync(p);
        if (!actual.equals(bytes)) throw Error("download mismatch");
        fs.writeFileSync(`${resultDir}/${target}-output.txt`, bytes);
        return {
          bytes: bytes.length,
          sha256: crypto.createHash("sha256").update(bytes).digest("hex"),
        };
      });
    // Explicit browser adapter persistence: store exported bytes, reload, and verify. Not guest disk persistence.
    for (let i = -1; i < 5; i++) {
      await timed("persist_reload", i, async () => {
        const bytes = fs
          .readFileSync(`${resultDir}/${target}-output.txt`)
          .toString("base64");
        await page.evaluate(async (data) => {
          await new Promise((resolve, reject) => {
            const q = indexedDB.open("bench", 1);
            q.onupgradeneeded = () => q.result.createObjectStore("files");
            q.onsuccess = () => {
              const db = q.result,
                t = db.transaction("files", "readwrite");
              t.objectStore("files").put(data, "output");
              t.oncomplete = () => {
                db.close();
                resolve();
              };
              t.onerror = () => reject(t.error);
            };
            q.onerror = () => reject(q.error);
          });
        }, bytes);
        await page.reload();
        await page.waitForFunction(() => window.ready === true);
        const got = await page.evaluate(
          () =>
            new Promise((resolve, reject) => {
              const q = indexedDB.open("bench", 1);
              q.onsuccess = () => {
                const db = q.result,
                  t = db.transaction("files"),
                  r = t.objectStore("files").get("output");
                r.onsuccess = () => {
                  resolve(r.result);
                  db.close();
                };
                r.onerror = () => reject(r.error);
              };
            }),
        );
        if (got !== bytes) throw Error("reload mismatch");
        return { verified: true, bytes: Buffer.from(got, "base64").length };
      });
    }
    await page.evaluate(() => adapter.boot());
    const session = await context.newCDPSession(page);
    await session.send("Performance.enable");
    out.browserMetrics = await session.send("Performance.getMetrics");
    out.storage = await page.evaluate(async () => ({
      estimate: await navigator.storage.estimate(),
      persisted: await navigator.storage.persisted(),
      uaMemoryAvailable:
        typeof performance.measureUserAgentSpecificMemory === "function",
      jsMemory: performance.memory
        ? {
            used: performance.memory.usedJSHeapSize,
            total: performance.memory.totalJSHeapSize,
          }
        : null,
    }));
    out.buildSupport = await page.evaluate(() =>
      adapter.exec("command -v cc || echo NO_CC"),
    );
    save();
  } finally {
    save();
    await browser.close();
  }
})().catch((e) => {
  console.error(e.message);
  process.exitCode = 1;
});
