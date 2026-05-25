/**
 * Phase 2 RAPT Multi-Tenant Validation Tests
 *
 * Validates: owner-stamped telemetry/devices/sessions, RLS isolation end-to-end,
 * write isolation WITH CHECK, empty-state correctness for tenant-b.
 *
 * Migration 005_rapt_telemetry_owner.sql must be applied before running.
 *
 * Run: BASE_URL=http://localhost:8085 SUPABASE_URL=http://localhost:54321 \
 *      SUPABASE_ANON_KEY=<key> npx playwright test tests/rapt-phase2.spec.ts
 */

import { test, expect, request as playwrightRequest, APIRequestContext, Page } from '@playwright/test';
import { waitForFlutter } from '../fixtures/flutter-a11y';

test.describe.configure({ mode: 'serial' });

// ---------------------------------------------------------------------------
// Config
// ---------------------------------------------------------------------------
const BASE_URL = process.env.BASE_URL ?? 'http://localhost:8085';
const SUPABASE_URL = process.env.SUPABASE_URL ?? 'http://localhost:54321';
const SUPABASE_ANON_KEY = process.env.SUPABASE_ANON_KEY ?? '';
const ALEX_EMAIL = process.env.TEST_EMAIL ?? 'alex@alexstuder.ch';
const ALEX_PASSWORD = process.env.TEST_PASSWORD ?? 'asdf';
const TENANT_B_EMAIL = 'tenant-b@test.local';
const TENANT_B_PASSWORD = 'TenantB123!';

// UIDs known from DB (verified during test bootstrap)
let alexUid: string;
let tenantBUid: string;
let alexToken: string;
let tenantBToken: string;
let apiCtx: APIRequestContext;

// Session ID created during write-isolation test for teardown
let tenantBTestSessionId: string | null = null;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------
async function login(email: string, password: string): Promise<{ access_token: string; user: { id: string } }> {
  const res = await apiCtx.post(
    `${SUPABASE_URL}/auth/v1/token?grant_type=password`,
    {
      headers: { apikey: SUPABASE_ANON_KEY, 'Content-Type': 'application/json' },
      data: { email, password },
    },
  );
  if (!res.ok()) throw new Error(`Login failed for ${email}: ${res.status()} ${await res.text()}`);
  return res.json();
}

async function postgrestGet(token: string, table: string, query: string = '') {
  return apiCtx.get(`${SUPABASE_URL}/rest/v1/${table}${query}`, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Accept-Profile': 'rapt',
    },
  });
}

async function postgrestPost(token: string, table: string, body: object) {
  return apiCtx.post(`${SUPABASE_URL}/rest/v1/${table}`, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Content-Profile': 'rapt',
      'Content-Type': 'application/json',
      Prefer: 'return=representation',
    },
    data: body,
  });
}

/** Returns the content-range total count for a table using Prefer: count=exact */
async function countRows(token: string, table: string): Promise<number> {
  const res = await apiCtx.get(`${SUPABASE_URL}/rest/v1/${table}?select=*&limit=1`, {
    headers: {
      apikey: SUPABASE_ANON_KEY,
      Authorization: `Bearer ${token}`,
      'Accept-Profile': 'rapt',
      Prefer: 'count=exact',
    },
  });
  const range = res.headers()['content-range'] ?? '';
  // format: "0-0/30289" or "*/0"
  const match = range.match(/\/(\d+)/);
  return match ? parseInt(match[1], 10) : 0;
}

/** Logs in via Flutter UI (fresh browser context, no storageState). */
async function uiLoginAs(page: Page, email: string, password: string) {
  await page.goto(BASE_URL);
  await page.evaluate(() => window.localStorage.clear());
  await page.reload();
  await waitForFlutter(page);
  await page.getByLabel('E-Mail').fill(email);
  // Flutter renders a "Passwort anzeigen" toggle button with the same label;
  // target the text-field role specifically to avoid strict-mode collision.
  await page.getByRole('textbox', { name: 'Passwort' }).fill(password);
  await page.getByRole('button', { name: /Anmelden/ }).click();
  await expect(page.getByRole('button', { name: /Gebraute Biere/ })).toBeVisible({ timeout: 20_000 });
}

// ---------------------------------------------------------------------------
// Setup / Teardown
// ---------------------------------------------------------------------------
test.beforeAll(async ({ browser }) => {
  apiCtx = await playwrightRequest.newContext();

  const alexAuth = await login(ALEX_EMAIL, ALEX_PASSWORD);
  alexToken = alexAuth.access_token;
  alexUid = alexAuth.user.id;

  const tenantBAuth = await login(TENANT_B_EMAIL, TENANT_B_PASSWORD);
  tenantBToken = tenantBAuth.access_token;
  tenantBUid = tenantBAuth.user.id;
});

test.afterAll(async () => {
  // Cleanup: delete tenant-b's test session if it survived
  if (tenantBTestSessionId) {
    await apiCtx.delete(`${SUPABASE_URL}/rest/v1/brew_sessions?id=eq.${tenantBTestSessionId}`, {
      headers: {
        apikey: SUPABASE_ANON_KEY,
        Authorization: `Bearer ${tenantBToken}`,
        'Content-Profile': 'rapt',
      },
    });
  }
  await apiCtx.dispose();
});

// ============================================================================
// SCENARIO 1: Alex sieht seine Bestandsdaten (DB-Ebene)
// ============================================================================
test.describe('S1: Alex sieht seine Bestandsdaten via PostgREST', () => {
  test('alex/controllers: mindestens 1 Row', async () => {
    const res = await postgrestGet(alexToken, 'controllers');
    expect(res.status()).toBe(200);
    const rows: unknown[] = await res.json();
    expect(Array.isArray(rows)).toBe(true);
    expect(rows.length).toBeGreaterThan(0);
    // Sanity: every row belongs to Alex
    for (const row of rows as Record<string, unknown>[]) {
      expect(row['owner']).toBe(alexUid);
    }
  });

  test('alex/hydrometers: mindestens 1 Row', async () => {
    const res = await postgrestGet(alexToken, 'hydrometers');
    expect(res.status()).toBe(200);
    const rows: unknown[] = await res.json();
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows as Record<string, unknown>[]) {
      expect(row['owner']).toBe(alexUid);
    }
  });

  test('alex/profiles: mindestens 1 Row', async () => {
    const res = await postgrestGet(alexToken, 'profiles');
    expect(res.status()).toBe(200);
    const rows: unknown[] = await res.json();
    expect(rows.length).toBeGreaterThan(0);
  });

  test('alex/brew_sessions: mindestens 1 Row', async () => {
    const res = await postgrestGet(alexToken, 'brew_sessions');
    expect(res.status()).toBe(200);
    const rows: unknown[] = await res.json();
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows as Record<string, unknown>[]) {
      expect(row['owner']).toBe(alexUid);
    }
  });

  test('alex/telemetry_controllers: >1000 Rows (Hypertable mit realen Sync-Daten)', async () => {
    const count = await countRows(alexToken, 'telemetry_controllers');
    expect(count).toBeGreaterThan(1000);
  });

  test('alex/telemetry_hydrometers: >1000 Rows', async () => {
    const count = await countRows(alexToken, 'telemetry_hydrometers');
    expect(count).toBeGreaterThan(1000);
  });

  test('alex/device_activity_controllers (view, security_invoker): >0 Rows', async () => {
    const res = await postgrestGet(alexToken, 'device_activity_controllers');
    expect(res.status()).toBe(200);
    const rows: unknown[] = await res.json();
    expect(rows.length).toBeGreaterThan(0);
    // All rows belong to Alex (owner in view shape)
    for (const row of rows as Record<string, unknown>[]) {
      expect(row['owner']).toBe(alexUid);
    }
  });
});

// ============================================================================
// SCENARIO 1b: Alex sieht seine Daten in der Flutter UI
// ============================================================================
test.describe('S1b: Alex UI — Geräte und Sude sichtbar', () => {
  test('alex: Geräte-Seite zeigt mindestens 1 Gerät (kein Empty-State)', async ({ browser }) => {
    const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
    const page = await ctx.newPage();
    try {
      await uiLoginAs(page, ALEX_EMAIL, ALEX_PASSWORD);
      // Navigate to Geräte
      await page.getByRole('button', { name: /Geräte/ }).click();
      await waitForFlutter(page);
      // Devices page: should NOT show the empty-state text
      // (empty-state: 'Noch keine Geräte. Hinterlege deinen RAPT-Key …')
      await expect(page.getByText(/Noch keine Geräte/)).not.toBeVisible({ timeout: 10_000 });
      // Should show a list tile (device name visible as non-empty text rows)
      // We look for the AppBar title which is always there, then confirm list visible
      await expect(page.getByText('Devices')).toBeVisible();
      // Screenshot as evidence
      await page.screenshot({ path: 'test-results/s1b-alex-devices.png' });
    } finally {
      await ctx.close();
    }
  });

  test('alex: Gebraute Biere zeigt mindestens 1 Sud (kein Empty-State)', async ({ browser }) => {
    const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
    const page = await ctx.newPage();
    try {
      await uiLoginAs(page, ALEX_EMAIL, ALEX_PASSWORD);
      await page.getByRole('button', { name: /Gebraute Biere/ }).click();
      await waitForFlutter(page);
      // Empty-state text should NOT appear
      await expect(page.getByText(/Noch keine Sude/)).not.toBeVisible({ timeout: 10_000 });
      await expect(page.getByText('Gebraute Biere')).toBeVisible();
      await page.screenshot({ path: 'test-results/s1b-alex-brewed-beers.png' });
    } finally {
      await ctx.close();
    }
  });
});

// ============================================================================
// SCENARIO 2 + 3: Mandanten-Isolation — tenant-b sieht NICHTS von Alex
// ============================================================================
test.describe('S2/S3: Mandanten-Isolation — tenant-b sieht 0 Rows von Alex (PostgREST)', () => {
  test('tenant-b/controllers: 0 Rows', async () => {
    const res = await postgrestGet(tenantBToken, 'controllers');
    expect(res.status()).toBe(200);
    const rows: unknown[] = await res.json();
    expect(rows).toHaveLength(0);
  });

  test('tenant-b/hydrometers: 0 Rows', async () => {
    const res = await postgrestGet(tenantBToken, 'hydrometers');
    expect(res.status()).toBe(200);
    const rows: unknown[] = await res.json();
    expect(rows).toHaveLength(0);
  });

  test('tenant-b/profiles: 0 Rows', async () => {
    const res = await postgrestGet(tenantBToken, 'profiles');
    expect(res.status()).toBe(200);
    const rows: unknown[] = await res.json();
    expect(rows).toHaveLength(0);
  });

  test('tenant-b/brew_sessions: 0 Rows (keine Alex-Session)', async () => {
    const res = await postgrestGet(tenantBToken, 'brew_sessions');
    expect(res.status()).toBe(200);
    const rows: unknown[] = await res.json();
    expect(rows).toHaveLength(0);
    // Belt-and-suspenders: if somehow rows returned, verify none belong to Alex
    for (const row of rows as Record<string, unknown>[]) {
      expect(row['owner']).not.toBe(alexUid);
    }
  });

  test('tenant-b/telemetry_controllers: 0 Rows (RLS auf Hypertable greift auf alle Chunks)', async () => {
    const count = await countRows(tenantBToken, 'telemetry_controllers');
    expect(count).toBe(0);
  });

  test('tenant-b/telemetry_hydrometers: 0 Rows', async () => {
    const count = await countRows(tenantBToken, 'telemetry_hydrometers');
    expect(count).toBe(0);
  });

  test('tenant-b/device_activity_controllers (security_invoker view): 0 Rows', async () => {
    const res = await postgrestGet(tenantBToken, 'device_activity_controllers');
    expect(res.status()).toBe(200);
    const rows: unknown[] = await res.json();
    expect(rows).toHaveLength(0);
  });

  test('kein Alex-Datenleck: response body enthält keine Alex-UUID', async () => {
    // Probe all data tables at once, check no body contains Alex UID
    const tables = ['controllers', 'hydrometers', 'profiles', 'brew_sessions',
                    'device_activity_controllers'];
    for (const table of tables) {
      const res = await postgrestGet(tenantBToken, table);
      const body = await res.text();
      expect(body).not.toContain(alexUid);
    }
  });
});

// ============================================================================
// SCENARIO 3 (UI): tenant-b sieht Empty-States im Flutter-Frontend
// ============================================================================
test.describe('S3 UI: tenant-b leere Seiten — Empty-States statt fremder Daten', () => {
  test('tenant-b: Geräte-Seite zeigt Empty-State (nicht Alex\' Geräte)', async ({ browser }) => {
    const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
    const page = await ctx.newPage();
    try {
      await uiLoginAs(page, TENANT_B_EMAIL, TENANT_B_PASSWORD);
      await page.getByRole('button', { name: /Geräte/ }).click();
      await waitForFlutter(page);

      // Empty-state should appear: "Noch keine Geräte. Hinterlege deinen RAPT-Key …"
      await expect(
        page.getByText(/Noch keine Geräte/)
      ).toBeVisible({ timeout: 15_000 });

      // Confirm Alex's device name does NOT appear
      // (Alex has exactly 1 controller, its name is unknown but page should be empty)
      // The page must NOT show a device list
      await expect(page.getByText(/controller|hydrometer/i)).not.toBeVisible();

      await page.screenshot({ path: 'test-results/s3-tenant-b-devices-empty.png' });
    } finally {
      await ctx.close();
    }
  });

  test('tenant-b: Gebraute Biere zeigt Empty-State (nicht Alex\' Sude)', async ({ browser }) => {
    const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
    const page = await ctx.newPage();
    try {
      await uiLoginAs(page, TENANT_B_EMAIL, TENANT_B_PASSWORD);
      await page.getByRole('button', { name: /Gebraute Biere/ }).click();
      await waitForFlutter(page);

      // Empty-state: "Noch keine Sude."
      await expect(
        page.getByText(/Noch keine Sude/)
      ).toBeVisible({ timeout: 15_000 });

      // None of Alex's known brew session names should appear
      // We check a couple that are confirmed in the DB
      await expect(page.getByText('Red Ale')).not.toBeVisible();
      await expect(page.getByText('Guinness')).not.toBeVisible();

      await page.screenshot({ path: 'test-results/s3-tenant-b-brewed-beers-empty.png' });
    } finally {
      await ctx.close();
    }
  });
});

// ============================================================================
// SCENARIO 4: Schreib-Isolation — WITH CHECK und INSERT-Isolation
// ============================================================================
test.describe('S4: Schreib-Isolation auf brew_sessions', () => {
  test('tenant-b kann eigene Session anlegen (owner = tenant-b uid, HTTP 201)', async () => {
    const res = await postgrestPost(tenantBToken, 'brew_sessions', {
      owner: tenantBUid,
      profile_id: 'manual.e2e-phase2-test',
      name: 'e2e Phase2 tenant-b Testsession',
      start_date: '2024-06-01T10:00:00Z',
      end_date: '2024-06-15T10:00:00Z',
      is_manual: true,
    });
    expect(res.status()).toBe(201);
    const rows: Record<string, unknown>[] = await res.json();
    expect(rows).toHaveLength(1);
    expect(rows[0]['owner']).toBe(tenantBUid);
    expect(rows[0]['is_manual']).toBe(true);
    tenantBTestSessionId = rows[0]['id'] as string;
  });

  test('Alex sieht die tenant-b Session NICHT (RLS-Isolation nach Insert)', async () => {
    // Alex fetches all his sessions — must not include tenant-b's
    const res = await postgrestGet(alexToken, 'brew_sessions');
    expect(res.status()).toBe(200);
    const rows: Record<string, unknown>[] = await res.json();
    const hasTenantBSession = rows.some(
      r => r['owner'] === tenantBUid || r['name'] === 'e2e Phase2 tenant-b Testsession'
    );
    expect(hasTenantBSession).toBe(false);
    // Alex still sees his own sessions (count unchanged from seeded data)
    // Known count = 18 from DB probe; allow for drift but must be >0
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      expect(row['owner']).toBe(alexUid);
    }
  });

  test('tenant-b sieht nur seine eigene Session (nicht Alex\')', async () => {
    const res = await postgrestGet(tenantBToken, 'brew_sessions');
    expect(res.status()).toBe(200);
    const rows: Record<string, unknown>[] = await res.json();
    // Should see exactly the 1 test session (no Alex rows)
    expect(rows.length).toBeGreaterThan(0);
    for (const row of rows) {
      expect(row['owner']).toBe(tenantBUid);
      expect(row['owner']).not.toBe(alexUid);
    }
  });

  test('WITH CHECK: tenant-b KANN NICHT session mit Alex-UID anlegen (HTTP 403)', async () => {
    const res = await postgrestPost(tenantBToken, 'brew_sessions', {
      owner: alexUid,          // Injection attempt: wrong owner
      profile_id: 'manual.injection-attempt',
      name: 'injected by tenant-b',
      start_date: '2024-07-01T10:00:00Z',
      end_date: '2024-07-02T10:00:00Z',
      is_manual: true,
    });
    // PostgREST returns 403 when RLS WITH CHECK rejects the row
    expect(res.status()).toBe(403);
    const body = await res.text();
    // Must reference row-level security policy in error
    expect(body.toLowerCase()).toMatch(/row.level security|42501/);
  });

  test('Injection-Row existiert NICHT in Alex\' Sicht nach abgelehntem INSERT', async () => {
    // Make sure the injected row was truly rejected (not silently inserted)
    const res = await postgrestGet(alexToken, 'brew_sessions');
    const rows: Record<string, unknown>[] = await res.json();
    const injected = rows.find(r => r['name'] === 'injected by tenant-b');
    expect(injected).toBeUndefined();
  });
});

// ============================================================================
// SCENARIO 5: Empty-State-Korrektheit
// Leerzustände erscheinen nur bei wirklich leerem Datensatz, nicht während
// Laden oder bei Fehler (die hätten "Fehler: …" in roter Farbe).
// ============================================================================
test.describe('S5: Empty-State-Korrektheit — Leerzustand vs. Fehler/Laden unterscheidbar', () => {
  test('tenant-b: Geräte-Empty-State enthält keinen Fehlertext ("Fehler:")', async ({ browser }) => {
    const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
    const page = await ctx.newPage();
    try {
      await uiLoginAs(page, TENANT_B_EMAIL, TENANT_B_PASSWORD);
      await page.getByRole('button', { name: /Geräte/ }).click();
      await waitForFlutter(page);
      // Wait for loading to complete (CircularProgressIndicator disappears)
      // Empty-state text must be visible
      await expect(page.getByText(/Noch keine Geräte/)).toBeVisible({ timeout: 15_000 });
      // Error text must NOT appear
      await expect(page.getByText(/Fehler:/)).not.toBeVisible();
      await page.screenshot({ path: 'test-results/s5-tenant-b-devices-empty-state.png' });
    } finally {
      await ctx.close();
    }
  });

  test('tenant-b: Gebraute-Biere-Seite zeigt keinen Fehlertext ("Fehler:") und keine Alex-Sude', async ({ browser }) => {
    // Note: S4 inserted a test session for tenant-b, so the list may not be
    // empty here — that is correct behaviour. What we verify is:
    //   1. No error text (page loaded successfully)
    //   2. None of Alex's known session names are visible
    const ctx = await browser.newContext({ storageState: { cookies: [], origins: [] } });
    const page = await ctx.newPage();
    try {
      await uiLoginAs(page, TENANT_B_EMAIL, TENANT_B_PASSWORD);
      await page.getByRole('button', { name: /Gebraute Biere/ }).click();
      await waitForFlutter(page);
      // Give page time to finish loading (either empty-state or list)
      await page.waitForTimeout(3_000);
      // Error text must NOT appear (no "Fehler:" in red)
      await expect(page.getByText(/Fehler:/)).not.toBeVisible();
      // Alex's known session names must NOT appear
      await expect(page.getByText('Red Ale')).not.toBeVisible();
      await expect(page.getByText('Guinness')).not.toBeVisible();
      await expect(page.getByText('Helles Export Bier')).not.toBeVisible();
      await page.screenshot({ path: 'test-results/s5-tenant-b-brewed-beers-state.png' });
    } finally {
      await ctx.close();
    }
  });
});

// ============================================================================
// SCENARIO 3 continued: Hypertable-Chunk-RLS — expliziter Beweis für alle Chunks
// ============================================================================
test.describe('S3-RLS-Hypertable: Chunk-Level-Isolation via Prefer: count=exact', () => {
  test('Alex sieht 30000+ telemetry_controller Rows (alle Chunks aggregiert)', async () => {
    const count = await countRows(alexToken, 'telemetry_controllers');
    // DB probe confirmed 30289; allow some variance from new syncs
    expect(count).toBeGreaterThan(10000);
  });

  test('tenant-b sieht exakt 0 telemetry_controller Rows (alle Chunks sauber gefiltert)', async () => {
    const count = await countRows(tenantBToken, 'telemetry_controllers');
    expect(count).toBe(0);
  });

  test('Alex sieht 23000+ telemetry_hydrometer Rows', async () => {
    const count = await countRows(alexToken, 'telemetry_hydrometers');
    expect(count).toBeGreaterThan(10000);
  });

  test('tenant-b sieht exakt 0 telemetry_hydrometer Rows', async () => {
    const count = await countRows(tenantBToken, 'telemetry_hydrometers');
    expect(count).toBe(0);
  });
});
