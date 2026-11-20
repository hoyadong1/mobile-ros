import { spawn } from 'node:child_process';
import fs from 'node:fs';
import path from 'node:path';
const dir = 'build/android-emulator';
fs.mkdirSync(dir, { recursive: true });
const args = process.argv.slice(2);
// Offline release review uses fake ROS/AI and real Android storage. No relay, account or certificate.
const offline = args[0] === '--offline';
if (offline) args.shift();
const deviceVideo = offline ? '/sdcard/mobile_ros_release.mp4' : '/sdcard/mobile_ros_qa.mp4';
const adb = `${process.env.LOCALAPPDATA}/Android/Sdk/platform-tools/adb.exe`;
// The account/relay fixture needs the private server code: without it the review runs offline.
const fixture = offline || !fs.existsSync('tool/android_cloud_fixture.mjs') ? null : spawn(process.execPath, ['tool/android_cloud_fixture.mjs'], { windowsHide: true, stdio: ['pipe', 'pipe', 'inherit'] });
fixture?.stdout.pipe(fs.createWriteStream(`${dir}/fixture.log`));
let recorder;
let linkWork = Promise.resolve();
let linkError;
const run = (exe, args, options = {}) => new Promise(resolve => {
  const child = spawn(exe, args, { windowsHide: true, ...options }); child.once('error', () => resolve(1)); child.once('exit', code => resolve(code ?? 1));
});
function approvalIntent(url, action = 'android.intent.action.VIEW') {
  linkWork = linkWork.then(async () => {
    const code = await run(adb, ['-s', 'emulator-5580', 'shell', 'am', 'start', '--activity-single-top',
      '-n', 'com.hoyadong.ros_tester/com.example.ros_tester.MainActivity', '-a', action, '-d', url], { stdio: 'ignore' });
    if (code !== 0) throw new Error('Could not deliver a QA approval intent.');
  }).catch(error => { linkError = error; process.stderr.write(`${error.message}\n`); });
}
try {
  if (fixture) {
    await new Promise((resolve, reject) => {
      const timeout = setTimeout(() => reject(new Error('Fixture did not start.')), 30000);
      fixture.stdout.on('data', data => { if (String(data).includes('fixture ready')) { clearTimeout(timeout); resolve(); } });
      fixture.once('exit', () => { clearTimeout(timeout); reject(new Error('Fixture exited.')); });
    });
    const cert = fs.readFileSync(`${dir}/qa-cert.pem`).toString('base64'); // public test certificate only
    const code = fs.readFileSync(`${dir}/claim-code.txt`, 'utf8');
    args.push(`--dart-define=QA_CERT=${cert}`, `--dart-define=QA_CODE=${code}`);
  }
  const flutter = process.env.ANDROID_QA_FLUTTER;
  if (!flutter) throw new Error('ANDROID_QA_FLUTTER must name flutter.bat.');
  process.exitCode = await new Promise(resolve => {
    const child = spawn(flutter, [...args, '-d', 'emulator-5580'],
      { shell: true, windowsHide: true, stdio: ['ignore', 'pipe', 'pipe'] });
    function line(text) {
      if (text.includes('QA_LINK_READY')) approvalIntent('https://mobile-ros.com/link/ABCD-EFGH');
      if (text.includes('QA_LINK_REJECTED_READY')) {
        approvalIntent('https://example.invalid/link/ZZZZ-9999');
        approvalIntent('http://mobile-ros.com/link/ZZZZ-9999');
        approvalIntent('https://mobile-ros.com/other/ZZZZ-9999');
        approvalIntent('https://mobile-ros.com/link/ZZZZ-9999', 'android.intent.action.SEND');
        approvalIntent('https://mobile-ros.com/link/WXYZ-2345');
      }
      if (text.includes('QA_BACKGROUND_NOW')) {
        spawn(adb, ['-s', 'emulator-5580', 'shell', 'input', 'keyevent', '3'], { windowsHide: true, stdio: 'ignore' });
        // Let Android report paused and the independent observer confirm STOP, then resume so the
        // test can render its cleanup frame instead of waiting forever for a background VSYNC.
        setTimeout(() => spawn(adb, ['-s', 'emulator-5580', 'shell', 'am', 'start', '--activity-reorder-to-front', '--activity-single-top', '-n',
          'com.hoyadong.ros_tester/com.example.ros_tester.MainActivity'], { windowsHide: true, stdio: 'ignore' }), 2500);
      }
      const match = /QA_SCREEN ([a-z-]+)/.exec(text);
      if (match) {
        if (match[1] === 'signin' || match[1] === 'release-connect') spawn(adb, ['-s', 'emulator-5580', 'shell', 'pm', 'grant',
          'com.hoyadong.ros_tester', 'android.permission.POST_NOTIFICATIONS'], { windowsHide: true, stdio: 'ignore' });
        if (!recorder) recorder = spawn(adb, ['-s', 'emulator-5580', 'shell', 'screenrecord', '--time-limit', '180', deviceVideo], { windowsHide: true, stdio: 'ignore' });
        const target = fs.createWriteStream(path.join(dir, `${match[1]}.png`));
        spawn(adb, ['-s', 'emulator-5580', 'exec-out', 'screencap', '-p'], { windowsHide: true }).stdout.pipe(target);
      }
    }
    let pending = '';
    child.stdout.on('data', data => {
      process.stdout.write(data);
      pending += String(data);
      const lines = pending.split('\n'); pending = lines.pop();
      for (const text of lines) line(text);
    });
    child.stderr.pipe(process.stderr); child.once('exit', result => resolve(result ?? 1));
    child.once('error', () => resolve(1));
  });
  await linkWork;
  if (linkError) process.exitCode = 1;
} finally {
  if (recorder) {
    await run(adb, ['-s', 'emulator-5580', 'shell', 'pkill', '-2', 'screenrecord'], { stdio: 'ignore' });
    await new Promise(resolve => setTimeout(resolve, 1000));
    await run(adb, ['-s', 'emulator-5580', 'pull', deviceVideo, `${dir}/${offline ? 'release-review' : 'mobile-ros-review'}.mp4`], { stdio: 'inherit' });
  }
  fixture?.stdin.end();
}
