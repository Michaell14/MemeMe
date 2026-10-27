// Renders Resources/DMG/background.html to the window backgrounds scripts/build-dmg.sh puts in
// MemeMe.dmg: background.png (notarized builds) and background-open-anyway.png (builds that are not
// notarized, with the Open Anyway hint), each at 660×400 and @2x. Run it after changing the HTML and
// commit the PNGs; CI doesn't render them.
//
// Usage:  node scripts/render-dmg-background.cjs
// Needs Node and Playwright with Chromium (npm install -g playwright && npx playwright install chromium).
const path = require("path");
const { pathToFileURL } = require("url");
const { chromium } = require("playwright");

const DIR = path.join(__dirname, "..", "Resources", "DMG");
const SOURCE = pathToFileURL(path.join(DIR, "background.html")).href;
const VARIANTS = [
  { name: "background", query: "" },
  { name: "background-open-anyway", query: "?hint" },
];

(async () => {
  const browser = await chromium.launch();
  try {
    for (const scale of [1, 2]) {
      const page = await browser.newPage({ viewport: { width: 660, height: 400 }, deviceScaleFactor: scale });
      for (const variant of VARIANTS) {
        await page.goto(SOURCE + variant.query, { waitUntil: "networkidle" });
        await page.evaluate(() => document.fonts.ready);
        const file = path.join(DIR, `${variant.name}${scale === 2 ? "@2x" : ""}.png`);
        await page.screenshot({ path: file, omitBackground: false });
        console.log(`==> ${path.relative(process.cwd(), file)}`);
      }
      await page.close();
    }
  } finally {
    await browser.close();
  }
})().catch((error) => {
  console.error(error);
  process.exit(1);
});
