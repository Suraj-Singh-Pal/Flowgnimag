const fs = require('fs');
const path = require('path');

const backendRoot = path.resolve(__dirname, '..');
const envPath = path.join(backendRoot, '.env');

function printUsage() {
  console.log('Usage: npm run push:env:from-sa -- <path-to-service-account.json>');
  console.log('Example: npm run push:env:from-sa -- C:\\Users\\Lenovo\\Downloads\\service-account.json');
}

function parseJsonFile(filePath) {
  const raw = fs.readFileSync(filePath, 'utf8');
  return JSON.parse(raw);
}

function upsertEnvValue(envText, key, value) {
  const safeValue = String(value ?? '').trim();
  const line = `${key}=${safeValue}`;
  const re = new RegExp(`^${key}=.*$`, 'm');
  if (re.test(envText)) {
    return envText.replace(re, line);
  }
  return `${envText.trimEnd()}\n${line}\n`;
}

function main() {
  const args = process.argv.slice(2);
  const inputPath = args[0];

  if (!inputPath || inputPath === '--help' || inputPath === '-h') {
    printUsage();
    process.exit(inputPath ? 0 : 1);
  }

  const resolvedPath = path.resolve(process.cwd(), inputPath);
  if (!fs.existsSync(resolvedPath)) {
    console.error(`Service account file not found: ${resolvedPath}`);
    process.exit(1);
  }

  let json;
  try {
    json = parseJsonFile(resolvedPath);
  } catch (error) {
    console.error(`Could not parse JSON: ${error.message || error}`);
    process.exit(1);
  }

  const projectId = String(json.project_id || '').trim();
  const clientEmail = String(json.client_email || '').trim();
  const privateKey = String(json.private_key || '').replace(/\r?\n/g, '\\n').trim();

  if (!projectId || !clientEmail || !privateKey) {
    console.error('Invalid service account JSON: required fields project_id, client_email, private_key are missing.');
    process.exit(1);
  }

  let envText = '';
  if (fs.existsSync(envPath)) {
    envText = fs.readFileSync(envPath, 'utf8');
  }

  envText = upsertEnvValue(envText, 'FIREBASE_PROJECT_ID', projectId);
  envText = upsertEnvValue(envText, 'FIREBASE_CLIENT_EMAIL', clientEmail);
  envText = upsertEnvValue(envText, 'FIREBASE_PRIVATE_KEY', privateKey);

  fs.writeFileSync(envPath, envText, 'utf8');

  console.log('Updated backend/.env with Firebase service account values:');
  console.log('- FIREBASE_PROJECT_ID');
  console.log('- FIREBASE_CLIENT_EMAIL');
  console.log('- FIREBASE_PRIVATE_KEY');
  console.log('Next: restart backend and run `npm run push:check`.');
}

main();
