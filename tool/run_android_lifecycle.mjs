// Local-only, headless Android check. The selected QA emulator must already be running.
import { spawn, spawnSync } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
const runId = `restart-${Date.now()}`;
const dir = path.join('build', 'android-lifecycle', runId);
const adb = path.join(process.env.LOCALAPPDATA, 'Android', 'Sdk', 'platform-tools', 'adb.exe');
const appId = 'com.hoyadong.ros_tester';
fs.mkdirSync(dir, { recursive: true });
const adbRun = args => spawnSync(adb, ['-s', 'emulator-5580', ...args], { windowsHide: true, encoding: 'utf8', timeout: 15000 });
if (adbRun(['get-state']).stdout?.trim() !== 'device') throw new Error('Start the isolated emulator-5580 first.');
if (!process.env.ANDROID_QA_FLUTTER) throw new Error('Set ANDROID_QA_FLUTTER to flutter.bat.');

async function phase(name, expectedMarker, screenshot) {
  const folder = path.join(dir, name);
  fs.mkdirSync(folder);
  const log = fs.createWriteStream(path.join(folder, 'test.log'));
  const args = ['tool/run_android_review.mjs', '--offline', 'test', 'integration_test/android_lifecycle_test.dart',
    '--no-pub', '--reporter', 'expanded', `--dart-define=QA_RESTART_RUN=${runId}`,
    // Flutter integration tests otherwise uninstall the app (and erase preferences) after each run.
    ...(name === 'seed' ? ['--no-uninstall'] : [])];
  let output = '';
  const result = await new Promise((resolve, reject) => {
    const child = spawn(process.execPath, args, { windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    child.stdout.on('data', data => { output += String(data); process.stdout.write(data); log.write(data); });
    child.stderr.on('data', data => { process.stderr.write(data); log.write(data); });
    child.once('error', reject); child.once('exit', resolve);
  });
  await new Promise(resolve => log.end(resolve));
  if (result !== 0 || !output.includes('All tests passed!')) throw new Error(`${name} failed; see ${folder}/test.log.`);
  const match = new RegExp(`${expectedMarker} ${runId} pid=(\\d+)`).exec(output);
  if (!match) throw new Error(`${name} did not confirm its restart stage.`);
  for (const file of [screenshot, 'lifecycle-links.png', 'release-review.mp4']) {
    fs.copyFileSync(path.join('build', 'android-emulator', file), path.join(folder, file));
  }
  return Number(match[1]);
}

const seededPid = await phase('seed', 'QA_RESTART_SEEDED', 'lifecycle-seeded.png');
const installed = adbRun(['shell', 'pm', 'path', appId]);
if (installed.status !== 0 || !installed.stdout?.includes('package:')) throw new Error('The seeded QA app was uninstalled.');
const stopped = adbRun(['shell', 'am', 'force-stop', appId]);
if (stopped.status !== 0) throw new Error('Could not force-stop the isolated QA app.');
const afterStop = adbRun(['shell', 'pidof', appId]);
if (![0, 1].includes(afterStop.status)) throw new Error('Could not check the stopped QA process.');
if (afterStop.stdout?.trim()) throw new Error('QA app still has a process after force-stop.');
const restoredPid = await phase('restored', 'QA_RESTART_VERIFIED', 'lifecycle-restored.png');
if (seededPid === restoredPid) throw new Error('The app process was not replaced.');
fs.writeFileSync(path.join(dir, 'result.json'), JSON.stringify({ runId, seededPid, restoredPid,
  stoppedProcessAbsent: true, tests: 4, scenario: 'Local native storage and Android intent delivery; no production services.' }, null, 2));
console.log(`Lifecycle review passed: different Android PIDs ${seededPid} -> ${restoredPid}. Evidence: ${dir}`);
