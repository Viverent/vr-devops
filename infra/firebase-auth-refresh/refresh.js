'use strict';

// Modes:
//   export-prod   : lee DB prod tabla users (backoffice) + 4 TI investor_portal_users,
//                   listUsers firebase prod, escribe whitelist + prod-users-full al bucket
//   import-beta   : lee bucket, drop firebase auth beta, importUsers filtrados
//   import-dev    : igual que import-beta pero target dev

const admin = require('firebase-admin');
const { Storage } = require('@google-cloud/storage');
const { SecretManagerServiceClient } = require('@google-cloud/secret-manager');
const { Client } = require('pg');

const MODE = process.env.MODE;
const BUCKET = process.env.BUCKET;
const BUCKET_PREFIX = process.env.BUCKET_PREFIX || 'firebase-auth/';
const PROJECT_ID = process.env.PROJECT_ID;

const TI_INVESTOR_EMAILS = [
  'julian.valdivia@viverent.com',
  'samuel.sanchez@viverent.com',
  'ericx.urias@viverent.com',
  'adrian.gonzalez@viverent.com',
];

const secrets = new SecretManagerServiceClient();

function ts() { return new Date().toISOString(); }
function log(msg) { console.log(`[${ts()}] ${msg}`); }

async function accessSecret(name, project) {
  const [v] = await secrets.accessSecretVersion({
    name: `projects/${project}/secrets/${name}/versions/latest`,
  });
  return v.payload.data.toString('utf8');
}

async function exportProd() {
  if (!PROJECT_ID) throw new Error('PROJECT_ID required for export-prod');
  if (!BUCKET) throw new Error('BUCKET required');

  log('Leyendo whitelist desde DB prod identity');
  const dbUrl = await accessSecret(process.env.DB_URL_SECRET, PROJECT_ID);
  const cleanUrl = dbUrl.replace(/^postgresql\+asyncpg:\/\//, 'postgresql://');
  const pg = new Client({ connectionString: cleanUrl });
  await pg.connect();
  const backofficeRes = await pg.query('SELECT email, firebase_uid FROM users ORDER BY email');
  const tiRes = await pg.query(
    'SELECT email, firebase_uid FROM investor_portal_users WHERE email = ANY($1::text[]) ORDER BY email',
    [TI_INVESTOR_EMAILS]
  );
  await pg.end();
  const whitelist = [...backofficeRes.rows, ...tiRes.rows];
  log(`Whitelist size: ${whitelist.length} (backoffice=${backofficeRes.rows.length} + ti=${tiRes.rows.length})`);

  log('Inicializando firebase-admin con ADC project=' + PROJECT_ID);
  admin.initializeApp({ projectId: PROJECT_ID });

  log('listUsers Firebase prod paginated');
  const all = [];
  let nextPage;
  do {
    const result = await admin.auth().listUsers(1000, nextPage);
    all.push(...result.users.map(u => u.toJSON()));
    nextPage = result.pageToken;
  } while (nextPage);
  log(`Firebase prod users: ${all.length}`);

  const storage = new Storage();
  const bucketName = BUCKET.replace(/^gs:\/\//, '');
  const whitelistObj = `${BUCKET_PREFIX}whitelist.json`;
  const fullObj = `${BUCKET_PREFIX}prod-users-full.json`;

  log(`Subiendo ${whitelistObj}`);
  await storage.bucket(bucketName).file(whitelistObj).save(JSON.stringify(whitelist, null, 2), {
    contentType: 'application/json',
  });
  log(`Subiendo ${fullObj} (${all.length} users)`);
  await storage.bucket(bucketName).file(fullObj).save(JSON.stringify(all), {
    contentType: 'application/json',
  });
  log('export-prod completed');
}

async function importEnv(targetEnv) {
  if (!PROJECT_ID) throw new Error('PROJECT_ID required for import');
  if (!BUCKET) throw new Error('BUCKET required');

  log(`Inicializando firebase-admin target=${PROJECT_ID}`);
  admin.initializeApp({ projectId: PROJECT_ID });

  const storage = new Storage();
  const bucketName = BUCKET.replace(/^gs:\/\//, '');

  log('Leyendo whitelist y prod-users-full del bucket');
  const [whitelistBuf] = await storage.bucket(bucketName).file(`${BUCKET_PREFIX}whitelist.json`).download();
  const [fullBuf] = await storage.bucket(bucketName).file(`${BUCKET_PREFIX}prod-users-full.json`).download();
  const whitelist = JSON.parse(whitelistBuf.toString('utf8'));
  const fullUsers = JSON.parse(fullBuf.toString('utf8'));

  const whitelistUidSet = new Set(whitelist.map(w => w.firebase_uid));
  const toImport = fullUsers.filter(u => whitelistUidSet.has(u.uid));
  log(`Filtrados: ${toImport.length} / ${fullUsers.length} (whitelist=${whitelist.length})`);

  log(`listUsers target ${targetEnv}`);
  const existing = [];
  let nextPage;
  do {
    const r = await admin.auth().listUsers(1000, nextPage);
    existing.push(...r.users.map(u => u.uid));
    nextPage = r.pageToken;
  } while (nextPage);
  log(`Existing users en ${targetEnv}: ${existing.length}`);

  if (existing.length > 0) {
    log(`deleteUsers ${existing.length} (drop completo)`);
    const chunks = [];
    for (let i = 0; i < existing.length; i += 1000) chunks.push(existing.slice(i, i + 1000));
    for (const c of chunks) {
      const result = await admin.auth().deleteUsers(c);
      log(`deleteUsers batch=${c.length} success=${result.successCount} failure=${result.failureCount}`);
      if (result.failureCount > 0) {
        result.errors.forEach(e => log(`  delete error idx=${e.index} ${e.error.message}`));
      }
    }
  }

  log('Leyendo signerKey de prod desde secret prod_firebase_signer_key');
  const signerKeyB64 = await accessSecret('prod_firebase_signer_key', PROJECT_ID);

  const importRecords = toImport.map(u => ({
    uid: u.uid,
    email: u.email,
    emailVerified: u.emailVerified === true || u.emailVerified === 'true',
    displayName: u.displayName,
    disabled: u.disabled === true || u.disabled === 'true',
    passwordHash: u.passwordHash ? Buffer.from(u.passwordHash, 'base64') : undefined,
    passwordSalt: u.passwordSalt ? Buffer.from(u.passwordSalt, 'base64') : undefined,
    providerData: (u.providerData || []).map(p => ({
      uid: p.uid,
      providerId: p.providerId,
      displayName: p.displayName,
      email: p.email,
      photoURL: p.photoURL,
    })),
  }));

  const hashOptions = {
    hash: {
      algorithm: 'SCRYPT',
      key: Buffer.from(signerKeyB64, 'base64'),
      saltSeparator: Buffer.from('Bw==', 'base64'),
      rounds: 8,
      memoryCost: 14,
    },
  };

  log(`importUsers count=${importRecords.length}`);
  const importResult = await admin.auth().importUsers(importRecords, hashOptions);
  log(`importUsers success=${importResult.successCount} failure=${importResult.failureCount}`);
  if (importResult.failureCount > 0) {
    importResult.errors.forEach(e => log(`  import error idx=${e.index} ${e.error.message}`));
    process.exit(1);
  }

  log(`import-${targetEnv} completed`);
}

(async () => {
  log(`MODE=${MODE} PROJECT_ID=${PROJECT_ID} BUCKET=${BUCKET}`);
  if (MODE === 'export-prod') await exportProd();
  else if (MODE === 'import-beta') await importEnv('beta');
  else if (MODE === 'import-dev') await importEnv('dev');
  else { console.error(`unknown MODE=${MODE}`); process.exit(1); }
})().catch(err => {
  console.error(`[${ts()}] FATAL`, err);
  process.exit(1);
});
