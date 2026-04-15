const { test, before, after } = require('node:test');
const assert = require('node:assert/strict');
const path = require('node:path');
const fs = require('node:fs');
const request = require('supertest');

const testDbPath = path.join(__dirname, '..', 'data', `flowgnimag-test-${process.pid}.db`);
process.env.DB_PATH = testDbPath;
process.env.JWT_SECRET = 'flowgnimag_test_secret';
process.env.NODE_ENV = 'test';
process.env.ALLOW_FAKE_FCM_FOR_TESTS = '1';
process.env.FIREBASE_PROJECT_ID = 'test-project-id';
process.env.FIREBASE_CLIENT_EMAIL = 'firebase-adminsdk@test-project-id.iam.gserviceaccount.com';
process.env.FIREBASE_PRIVATE_KEY = '-----BEGIN PRIVATE KEY-----\\nTEST_KEY\\n-----END PRIVATE KEY-----\\n';

const { app } = require('../src/app');

let authToken = '';
const androidConfigPath = path.join(
  __dirname,
  '..',
  '..',
  'frontend',
  'flutter_app',
  'android',
  'app',
  'google-services.json'
);
const iosConfigPath = path.join(
  __dirname,
  '..',
  '..',
  'frontend',
  'flutter_app',
  'ios',
  'Runner',
  'GoogleService-Info.plist'
);
let createdAndroidConfig = false;
let createdIosConfig = false;

function cleanupDbFiles(basePath) {
  const suffixes = ['', '-shm', '-wal'];
  for (const suffix of suffixes) {
    const filePath = `${basePath}${suffix}`;
    try {
      fs.rmSync(filePath, { force: true });
    } catch {}
  }
}

before(async () => {
  cleanupDbFiles(testDbPath);
  if (!fs.existsSync(androidConfigPath)) {
    fs.writeFileSync(
      androidConfigPath,
      JSON.stringify(
        {
          project_info: { project_id: 'test-project-id' },
          client: [],
        },
        null,
        2
      ),
      'utf8'
    );
    createdAndroidConfig = true;
  }
  if (!fs.existsSync(iosConfigPath)) {
    fs.writeFileSync(iosConfigPath, '<plist version="1.0"><dict></dict></plist>', 'utf8');
    createdIosConfig = true;
  }

  const email = `push-test-${Date.now()}@example.com`;
  const res = await request(app)
    .post('/auth/signup')
    .send({
      name: 'Push Test User',
      email,
      password: 'password123',
    });

  assert.equal(res.status, 201);
  assert.equal(typeof res.body.token, 'string');
  assert.ok(res.body.token.length > 20);
  authToken = res.body.token;

  const regRes = await request(app)
    .post('/notifications/register')
    .set('Authorization', `Bearer ${authToken}`)
    .send({
      token: 'test-device-token-1',
      platform: 'android',
    });
  assert.equal(regRes.status, 200);
  assert.equal(regRes.body.success, true);
});

after(() => {
  if (createdAndroidConfig) {
    try {
      fs.rmSync(androidConfigPath, { force: true });
    } catch {}
  }
  if (createdIosConfig) {
    try {
      fs.rmSync(iosConfigPath, { force: true });
    } catch {}
  }
  cleanupDbFiles(testDbPath);
});

test('GET /notifications/doctor requires auth', async () => {
  const res = await request(app).get('/notifications/doctor');
  assert.equal(res.status, 401);
});

test('GET /notifications/doctor returns diagnostics payload', async () => {
  const res = await request(app)
    .get('/notifications/doctor')
    .set('Authorization', `Bearer ${authToken}`);

  assert.equal(res.status, 200);
  assert.equal(res.body.success, true);
  assert.equal(typeof res.body.ready, 'boolean');
  assert.equal(Array.isArray(res.body.missing), true);
  assert.equal(Array.isArray(res.body.recommendedActions), true);
  assert.equal(Array.isArray(res.body.checks), true);
  assert.equal(Array.isArray(res.body.devices), true);
});

test('GET /notifications/doctor includes device-registration missing item and action when no token exists', async () => {
  const email = `push-doctor-missing-${Date.now()}@example.com`;
  const signupRes = await request(app)
    .post('/auth/signup')
    .send({
      name: 'Push Doctor Missing User',
      email,
      password: 'password123',
    });

  assert.equal(signupRes.status, 201);
  const token = signupRes.body.token;
  assert.equal(typeof token, 'string');
  assert.ok(token.length > 20);

  const res = await request(app)
    .get('/notifications/doctor')
    .set('Authorization', `Bearer ${token}`);

  assert.equal(res.status, 200);
  assert.equal(res.body.success, true);
  assert.equal(Array.isArray(res.body.missing), true);
  assert.equal(Array.isArray(res.body.recommendedActions), true);

  const hasMissingDeviceRequirement = res.body.missing.some((item) =>
    String(item).includes('at least one push device token is registered')
  );
  assert.equal(hasMissingDeviceRequirement, true);

  const hasDeviceAction = res.body.recommendedActions.some((item) =>
    String(item).includes('/notifications/register')
  );
  assert.equal(hasDeviceAction, true);
});

test('GET /notifications/doctor clears device-registration missing item after token registration', async () => {
  const email = `push-doctor-ready-${Date.now()}@example.com`;
  const signupRes = await request(app)
    .post('/auth/signup')
    .send({
      name: 'Push Doctor Ready User',
      email,
      password: 'password123',
    });

  assert.equal(signupRes.status, 201);
  const token = signupRes.body.token;
  assert.equal(typeof token, 'string');
  assert.ok(token.length > 20);

  const registerRes = await request(app)
    .post('/notifications/register')
    .set('Authorization', `Bearer ${token}`)
    .send({
      token: `test-device-token-ready-${Date.now()}`,
      platform: 'android',
    });

  assert.equal(registerRes.status, 200);
  assert.equal(registerRes.body.success, true);

  const res = await request(app)
    .get('/notifications/doctor')
    .set('Authorization', `Bearer ${token}`);

  assert.equal(res.status, 200);
  assert.equal(res.body.success, true);
  assert.equal(Array.isArray(res.body.missing), true);
  assert.equal(Array.isArray(res.body.recommendedActions), true);

  const hasMissingDeviceRequirement = res.body.missing.some((item) =>
    String(item).includes('at least one push device token is registered')
  );
  assert.equal(hasMissingDeviceRequirement, false);

  const hasDeviceAction = res.body.recommendedActions.some((item) =>
    String(item).includes('/notifications/register')
  );
  assert.equal(hasDeviceAction, false);
});

test('POST /notifications/self-test returns not-ready details when prerequisites are missing', async () => {
  const email = `push-test-missing-${Date.now()}@example.com`;
  const signupRes = await request(app)
    .post('/auth/signup')
    .send({
      name: 'Push Missing User',
      email,
      password: 'password123',
    });
  assert.equal(signupRes.status, 201);
  const missingUserToken = signupRes.body.token;

  const res = await request(app)
    .post('/notifications/self-test')
    .set('Authorization', `Bearer ${missingUserToken}`)
    .send({
      title: 'Test Title',
      body: 'Test Body',
    });

  assert.equal(res.status, 400);
  assert.equal(res.body.success, false);
  assert.equal(res.body.error, 'Push pipeline is not ready');
  assert.equal(Array.isArray(res.body.missing), true);
  assert.ok(res.body.missing.length >= 1);
});

test('POST /notifications/self-test returns success when prerequisites are satisfied in test mode', async () => {
  const res = await request(app)
    .post('/notifications/self-test')
    .set('Authorization', `Bearer ${authToken}`)
    .send({
      title: 'Ready Test Title',
      body: 'Ready Test Body',
    });

  assert.equal(res.status, 200);
  assert.equal(res.body.success, true);
  assert.equal(res.body.ready, true);
  assert.equal(typeof res.body.sent, 'number');
  assert.ok(res.body.sent >= 1);
  assert.equal(typeof res.body.invalid, 'number');
});
