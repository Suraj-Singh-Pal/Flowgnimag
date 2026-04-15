const fs = require('fs');
const path = require('path');
const { spawnSync } = require('child_process');

const backendRoot = path.resolve(__dirname, '..');
const repoRoot = path.resolve(backendRoot, '..');

function printUsage() {
  console.log('Usage: npm run push:bootstrap -- --sa <service-account.json> --android <google-services.json> --ios <GoogleService-Info.plist>');
  console.log('Example: npm run push:bootstrap -- --sa C:\\Users\\Lenovo\\Downloads\\sa.json --android C:\\Users\\Lenovo\\Downloads\\google-services.json --ios C:\\Users\\Lenovo\\Downloads\\GoogleService-Info.plist');
}

function parseArgs(argv) {
  const out = {};
  for (let i = 0; i < argv.length; i += 1) {
    const key = argv[i];
    const value = argv[i + 1];
    if (!key.startsWith('--')) continue;
    out[key.slice(2)] = value;
    i += 1;
  }
  return out;
}

function assertFileExists(filePath, label) {
  if (!filePath) {
    throw new Error(`${label} path is required.`);
  }
  const resolved = path.resolve(process.cwd(), filePath);
  if (!fs.existsSync(resolved)) {
    throw new Error(`${label} file not found: ${resolved}`);
  }
  return resolved;
}

function ensureDir(filePath) {
  fs.mkdirSync(path.dirname(filePath), { recursive: true });
}

function copyFile(fromPath, toPath) {
  ensureDir(toPath);
  fs.copyFileSync(fromPath, toPath);
}

function runNodeScript(scriptPath, args = []) {
  const result = spawnSync(process.execPath, [scriptPath, ...args], {
    cwd: backendRoot,
    stdio: 'inherit',
    env: process.env,
  });
  if (result.status !== 0) {
    throw new Error(`Script failed: ${path.basename(scriptPath)}`);
  }
}

function main() {
  const argv = process.argv.slice(2);
  if (argv.includes('--help') || argv.includes('-h') || argv.length === 0) {
    printUsage();
    process.exit(argv.length === 0 ? 1 : 0);
  }

  const args = parseArgs(argv);

  const saPath = assertFileExists(args.sa, 'Service account JSON');
  const androidSource = assertFileExists(args.android, 'Android google-services.json');
  const iosSource = assertFileExists(args.ios, 'iOS GoogleService-Info.plist');

  const androidTarget = path.join(
    repoRoot,
    'frontend',
    'flutter_app',
    'android',
    'app',
    'google-services.json'
  );
  const iosTarget = path.join(
    repoRoot,
    'frontend',
    'flutter_app',
    'ios',
    'Runner',
    'GoogleService-Info.plist'
  );

  copyFile(androidSource, androidTarget);
  copyFile(iosSource, iosTarget);
  console.log('Copied Firebase app config files:');
  console.log(`- ${androidTarget}`);
  console.log(`- ${iosTarget}`);

  const importScript = path.join(backendRoot, 'scripts', 'import-firebase-service-account.js');
  runNodeScript(importScript, [saPath]);

  const checkScript = path.join(backendRoot, 'scripts', 'push-readiness-check.js');
  runNodeScript(checkScript);

  console.log('Push bootstrap completed successfully.');
}

try {
  main();
} catch (error) {
  console.error(error.message || error);
  process.exit(1);
}
