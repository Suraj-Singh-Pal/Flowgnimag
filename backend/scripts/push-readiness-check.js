const fs = require('fs');
const path = require('path');
const dotenv = require('dotenv');

const backendRoot = path.resolve(__dirname, '..');
const repoRoot = path.resolve(backendRoot, '..');
dotenv.config({ path: path.join(backendRoot, '.env') });

const checks = [];

function clean(value) {
  return String(value || '').trim();
}

function isLikelyUnset(value) {
  const v = clean(value).toLowerCase();
  if (!v) return true;
  return (
    v.includes('your-project-id') ||
    v.includes('your_key_line') ||
    v.includes('replace_me') ||
    v === 'changeme'
  );
}

function addCheck(ok, label, fix) {
  checks.push({ ok, label, fix });
}

const envKeys = [
  'FIREBASE_PROJECT_ID',
  'FIREBASE_CLIENT_EMAIL',
  'FIREBASE_PRIVATE_KEY',
];

for (const key of envKeys) {
  const value = process.env[key];
  addCheck(!isLikelyUnset(value), `${key} is configured`, `Set ${key} in backend/.env`);
}

const androidPath = path.join(
  repoRoot,
  'frontend',
  'flutter_app',
  'android',
  'app',
  'google-services.json'
);
const iosPath = path.join(
  repoRoot,
  'frontend',
  'flutter_app',
  'ios',
  'Runner',
  'GoogleService-Info.plist'
);

addCheck(
  fs.existsSync(androidPath),
  'Android Firebase config file exists (google-services.json)',
  'Add frontend/flutter_app/android/app/google-services.json from Firebase Console'
);
addCheck(
  fs.existsSync(iosPath),
  'iOS Firebase config file exists (GoogleService-Info.plist)',
  'Add frontend/flutter_app/ios/Runner/GoogleService-Info.plist from Firebase Console'
);

const passed = checks.filter((c) => c.ok).length;
const failed = checks.length - passed;

console.log('\nFLOWGNIMAG Push Readiness Report');
console.log('================================');
for (const check of checks) {
  console.log(`${check.ok ? '[PASS]' : '[FAIL]'} ${check.label}`);
}

if (failed > 0) {
  console.log('\nRequired fixes:');
  for (const check of checks.filter((c) => !c.ok)) {
    console.log(`- ${check.fix}`);
  }
  console.log('\nManual iOS reminder:');
  console.log('- In Xcode Runner target, enable Push Notifications and Background Modes > Remote notifications.');
  console.log(`\nResult: ${failed} blocking item(s) found.`);
  process.exit(1);
}

console.log('\nResult: all automated checks passed.');
console.log('Next: run app and execute Settings > Push Notifications > Run Full Push Self-Test.');
