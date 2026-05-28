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
// Auth: routes that require a logged-in user are handled automatically — the
// auditor logs in with the dedicated dark-mode-audit user (provisioned by
// `mix dark_mode.ensure_audit_user`). No cookie wrangling needed by the
// caller. Set STRIDE_AUDIT_EMAIL / STRIDE_AUDIT_PASSWORD to override the
// default credentials when running against a non-default environment.

import { chromium } from "playwright";
import { AxeBuilder } from "@axe-core/playwright";

const DEFAULT_AUDIT_EMAIL = "dark-mode-audit@stride.local";
const DEFAULT_AUDIT_PASSWORD = "DarkMode!AuditUser123";

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

// Routes that DO NOT require a logged-in user.
const PUBLIC_AUTH_ROUTES = ["/users/log-in", "/users/register", "/users/forgot-password"];

// Routes that require a logged-in user. The auditor logs in automatically.
const AUTHENTICATED_ROUTES = [
  "/boards",
  "/boards/new",
  "/agents",
  "/review",
  "/metrics",
  "/messages",
  "/resources",
  "/users/settings",
];

const ALL_ROUTES = [...MARKETING_ROUTES, ...PUBLIC_AUTH_ROUTES, ...AUTHENTICATED_ROUTES];

function isAuthenticated(route) {
  return AUTHENTICATED_ROUTES.includes(route) || route.startsWith("/boards/");
}

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

async function login(page, baseUrl) {
  const email = process.env.STRIDE_AUDIT_EMAIL ?? DEFAULT_AUDIT_EMAIL;
  const password = process.env.STRIDE_AUDIT_PASSWORD ?? DEFAULT_AUDIT_PASSWORD;

  await page.goto(`${baseUrl}/users/log-in`, { waitUntil: "networkidle" });
  await page.fill('#login_form_password input[name="user[email]"]', email);
  await page.fill('#login_form_password input[name="user[password]"]', password);
  // The login form uses LiveView's phx-trigger-action two-step dance: the
  // phx-submit handler sets trigger_submit=true, the next render adds the
  // action attribute that fires the real POST. Submitting the form directly
  // via JS bypasses the LV round-trip and goes straight to the controller.
  await Promise.all([
    page.waitForURL((url) => !url.pathname.endsWith("/users/log-in"), { timeout: 10_000 }),
    page.evaluate(() => {
      const form = document.getElementById("login_form_password");
      if (!form) throw new Error("login_form_password not found");
      form.action = "/users/log-in";
      form.method = "post";
      form.submit();
    }),
  ]);

  // Sanity check: the redirect after login lands somewhere other than the
  // log-in page. If we're still on /users/log-in the credentials are wrong.
  const url = new URL(page.url());
  if (url.pathname === "/users/log-in") {
    throw new Error(
      `Audit login failed for ${email}. Run 'mix dark_mode.ensure_audit_user' to provision the dev user, or set STRIDE_AUDIT_EMAIL / STRIDE_AUDIT_PASSWORD if you want to use a different account.`,
    );
  }
}

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
  const page = await context.newPage();

  // Log in if any authenticated route is in scope. The context's cookie jar
  // carries the session for every subsequent navigation.
  if (args.routes.some(isAuthenticated)) {
    await login(page, args.baseUrl);
  }
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
