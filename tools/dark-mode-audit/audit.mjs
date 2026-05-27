#!/usr/bin/env node
// Dark-mode contrast audit for Stride pages.
//
// Drives a real Chromium via Playwright. For each enumerated route, navigates
// to it, sets data-theme on <html> first to "light" and then to "dark", and
// runs axe-core's color-contrast rule. Outputs a structured report of failures
// grouped by route x theme and exits non-zero when any failures are found.
//
// Usage:
//   node audit.mjs                                # audit all routes in both themes
//   node audit.mjs --routes=/,/pricing            # audit specific routes
//   node audit.mjs --themes=dark                  # only dark theme
//   node audit.mjs --base-url=http://localhost:4000  # override base URL
//   node audit.mjs --json                         # machine-readable output (default: human)
//   node audit.mjs --help
//
// Auth: routes that require a logged-in user accept a STRIDE_AUDIT_SESSION
// env var (Phoenix session cookie value). Public marketing pages do not need
// it.

import { chromium } from "playwright";
import { AxeBuilder } from "@axe-core/playwright";

// --- Route catalog ---------------------------------------------------------
//
// Marketing routes are public and need no auth. Authenticated routes (used by
// later per-surface audit tasks) require STRIDE_AUDIT_SESSION to be set with
// a valid Phoenix session cookie.

const MARKETING_ROUTES = [
  "/",
  "/about",
  "/pricing",
  "/privacy",
  "/product",
  "/security",
  "/workflows",
  "/changelog",
];

const ALL_ROUTES = MARKETING_ROUTES; // extend as later tasks need authenticated routes.

// --- Argument parsing ------------------------------------------------------

function parseArgs(argv) {
  const args = {
    baseUrl: "http://localhost:4000",
    routes: ALL_ROUTES,
    themes: ["light", "dark"],
    json: false,
  };
  for (const raw of argv.slice(2)) {
    if (raw === "--help" || raw === "-h") {
      console.log(HELP_TEXT);
      process.exit(0);
    } else if (raw === "--json") {
      args.json = true;
    } else if (raw.startsWith("--base-url=")) {
      args.baseUrl = raw.slice("--base-url=".length);
    } else if (raw.startsWith("--routes=")) {
      args.routes = raw.slice("--routes=".length).split(",").map((s) => s.trim()).filter(Boolean);
    } else if (raw.startsWith("--themes=")) {
      args.themes = raw.slice("--themes=".length).split(",").map((s) => s.trim()).filter(Boolean);
    } else {
      console.error(`unknown arg: ${raw}`);
      process.exit(2);
    }
  }
  return args;
}

const HELP_TEXT = `dark-mode-audit — programmatic WCAG AA contrast audit for Stride

Usage: node audit.mjs [options]

Options:
  --base-url=<url>     Base URL (default: http://localhost:4000)
  --routes=<a,b,c>     Comma-separated routes (default: all marketing routes)
  --themes=<a,b>       light, dark, or both (default: both)
  --json               Emit JSON instead of human-readable output
  -h, --help           Show this help

Environment:
  STRIDE_AUDIT_SESSION  Phoenix session cookie value for authenticated routes
`;

// --- Audit -----------------------------------------------------------------

async function auditRoute(page, baseUrl, route, theme) {
  await page.goto(`${baseUrl}${route}`, { waitUntil: "networkidle" });

  // Set the theme attribute on <html> and let any CSS hot-reload settle.
  await page.evaluate((t) => {
    document.documentElement.setAttribute("data-theme", t);
    localStorage.setItem("phx:theme", t);
  }, theme);
  await page.waitForTimeout(150);

  // axe color-contrast only (we have our own coverage for the other axe rules
  // via credo/sobelow/etc). Skip decorative content (mock illustrations like
  // the marketing mini-board) — those elements are tagged data-decorative=true
  // and aria-hidden=true; their text exists only as visual filler and is not
  // meant to be read.
  const results = await new AxeBuilder({ page })
    .withRules(["color-contrast"])
    .exclude("[data-decorative]")
    .exclude("[data-decorative] *")
    .analyze();

  const violations = results.violations.flatMap((v) =>
    v.nodes.map((n) => ({
      rule: v.id,
      impact: v.impact,
      help: v.help,
      target: n.target.join(" "),
      summary: n.failureSummary,
      html: n.html,
    })),
  );

  return { route, theme, violationCount: violations.length, violations };
}

// --- Output ----------------------------------------------------------------

function printHuman(report) {
  const totalFailures = report.results.reduce((acc, r) => acc + r.violationCount, 0);
  for (const r of report.results) {
    const status = r.violationCount === 0 ? "OK" : `FAIL (${r.violationCount})`;
    console.log(`[${r.theme.padEnd(5)}] ${r.route.padEnd(20)} ${status}`);
    if (r.violationCount > 0) {
      for (const v of r.violations) {
        console.log(`  - ${v.impact ?? "n/a"}: ${v.target}`);
        if (v.summary) {
          for (const line of v.summary.split("\n")) {
            if (line.trim()) console.log(`      ${line.trim()}`);
          }
        }
      }
    }
  }
  console.log("");
  console.log(`Total: ${totalFailures} contrast violation(s) across ${report.results.length} route x theme audits`);
}

// --- Main ------------------------------------------------------------------

async function main() {
  const args = parseArgs(process.argv);
  const browser = await chromium.launch({ headless: true });
  const context = await browser.newContext();

  // Auth: if STRIDE_AUDIT_SESSION is present, install it as the Phoenix session
  // cookie for the base URL's host so authenticated routes work.
  if (process.env.STRIDE_AUDIT_SESSION) {
    const url = new URL(args.baseUrl);
    await context.addCookies([
      {
        name: "_kanban_key",
        value: process.env.STRIDE_AUDIT_SESSION,
        domain: url.hostname,
        path: "/",
        httpOnly: true,
        secure: url.protocol === "https:",
        sameSite: "Lax",
      },
    ]);
  }

  const page = await context.newPage();
  const results = [];
  for (const route of args.routes) {
    for (const theme of args.themes) {
      const result = await auditRoute(page, args.baseUrl, route, theme);
      results.push(result);
    }
  }

  await browser.close();

  const report = { baseUrl: args.baseUrl, generatedAt: new Date().toISOString(), results };
  if (args.json) {
    console.log(JSON.stringify(report, null, 2));
  } else {
    printHuman(report);
  }
  const totalFailures = results.reduce((acc, r) => acc + r.violationCount, 0);
  process.exit(totalFailures === 0 ? 0 : 1);
}

main().catch((err) => {
  console.error(err);
  process.exit(2);
});
