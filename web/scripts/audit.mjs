// Security gate for CI and deploys: fails on any high or critical advisory
// except the ones listed below. Remove an entry as soon as a fix is released.
import { execFileSync } from 'node:child_process';

const ALLOWED = new Map([
  // http-cache-semantics has no patched release. Astro only uses it at build
  // time to cache remote images, and this site has none.
  ['GHSA-ch52-4w7c-c8xp', 'http-cache-semantics: no fixed version, build-time only'],
]);

let output;
try {
  output = execFileSync('npm', ['audit', '--json'], { encoding: 'utf8', stdio: ['ignore', 'pipe', 'inherit'] });
} catch (error) {
  // npm exits non-zero when it finds anything; the report is still on stdout.
  output = error.stdout;
}

const report = JSON.parse(output);
const blocking = [];
for (const [name, entry] of Object.entries(report.vulnerabilities ?? {})) {
  for (const via of entry.via) {
    // Strings are packages that inherit an advisory reported on its source.
    if (typeof via === 'string' || !['high', 'critical'].includes(via.severity)) continue;
    const id = via.url?.split('/').pop() ?? String(via.source);
    if (ALLOWED.has(id)) console.log(`allowed ${id} (${ALLOWED.get(id)})`);
    else blocking.push(`${name}: ${via.title} (${id})`);
  }
}

if (blocking.length) {
  console.error(`High or critical advisories:\n${blocking.map((line) => `  ${line}`).join('\n')}`);
  process.exit(1);
}
console.log('No blocking advisories.');
