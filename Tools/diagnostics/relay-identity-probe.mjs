// Read-only toward the installed relay. All generated certificates live in a
// fresh private temporary directory; no live state or configuration is changed.
// node --experimental-strip-types Tools/diagnostics/relay-identity-probe.mjs /path/to/deepseek-harness-relay
import { mkdtemp } from 'node:fs/promises';
import { tmpdir } from 'node:os';
import { resolve, join } from 'node:path';
import { pathToFileURL } from 'node:url';

const relay = process.argv[2];
if (!relay) throw new Error('Provide the relay checkout path.');
const { loadCertificate } = await import(pathToFileURL(join(resolve(relay), 'src/tls.ts')).href);
const dir = await mkdtemp(join(tmpdir(), 'dsh-relay-identity-audit-'));
const options = {
  mode: 'self-signed', dir, certPath: '', keyPath: '',
  sans: ['localhost', '127.0.0.1', '192.0.2.10'],
};
const first = await loadCertificate(options);
const unchanged = await loadCertificate({ ...options, existing: first.record });
const moved = await loadCertificate({
  ...options, existing: unchanged.record,
  sans: ['localhost', '127.0.0.1', '192.0.2.11'],
});
const facts = {
  same_addresses_preserve_key: first.record.fingerprint === unchanged.record.fingerprint,
  changed_addresses_rotate_key: first.record.fingerprint !== moved.record.fingerprint,
  old_phone_pin_rejects_changed_key: first.record.fingerprint !== moved.record.fingerprint,
  live_relay_state_modified: false,
};
console.log(JSON.stringify(facts, null, 2));
if (!facts.same_addresses_preserve_key || !facts.changed_addresses_rotate_key) process.exitCode = 1;
