#!/usr/bin/env node
/**
 * Automated 4-Cloud-Drive Uploader for Agent MCP Releases via Chrome DevTools Protocol (CDP).
 *
 * Connects directly to the persistent Edge session on http://127.0.0.1:9222
 * (bypassing Playwright MCP's 50MB remote file-transfer cap) and uploads all
 * release packages from `cloud_drive_upload/<tag>/` into the `Agent MCP` folder
 * across Quark Drive, Baidu Netdisk, UC Drive, and China Mobile Cloud (139).
 *
 * Supports three automatic injection strategies per drive:
 *   1. Direct DOM `<input type="file">` via `DOM.setFileInputFiles({ objectId, files })`
 *   2. Detached/dynamic file chooser interception (`Page.setInterceptFileChooserDialog` + click "上传文件" -> `DOM.setFileInputFiles({ backendNodeId, files })`)
 *   3. Native Windows FileDropList clipboard + CDP `Paste` command onto the dropzone
 *
 * Usage:
 *   node scripts/upload_cloud_drives.cjs --status
 *   node scripts/upload_cloud_drives.cjs --tag v3.5.7
 *   node scripts/upload_cloud_drives.cjs --tag v3.5.7 --drives quark,baidu,uc,139
 */

const fs = require('fs');
const path = require('path');
const http = require('http');
const { spawnSync } = require('child_process');

const CDP_HOST = process.env.CDP_HOST || '127.0.0.1';
const CDP_PORT = Number(process.env.CDP_PORT || 9222);

const DRIVES = [
  {
    key: 'quark',
    name: '夸克网盘 (Quark)',
    matchUrl: (u) => u.includes('pan.quark.cn'),
    targetUrl: 'https://pan.quark.cn/list#/list/all/c848ce6b47214b9aa0815dd76f557477-Agent%20MCP',
    folderFid: 'c848ce6b47214b9aa0815dd76f557477',
    selectors: [
      'input#ListHeader-file',
      'input[type="file"]:not([webkitdirectory])',
    ],
  },
  {
    key: 'baidu',
    name: '百度网盘 (Baidu)',
    matchUrl: (u) => u.includes('pan.baidu.com'),
    targetUrl: 'https://pan.baidu.com/disk/main#/index?category=all&path=%2FAgent%20MCP',
    selectors: [
      'input[type="file"][name="html5uploader"]:not([webkitdirectory]):not([accept=".torrent"])',
      'input[type="file"]:not([webkitdirectory]):not([accept=".torrent"])',
    ],
  },
  {
    key: 'uc',
    name: 'UC网盘 (UC)',
    matchUrl: (u) => u.includes('drive.uc.cn'),
    targetUrl: 'https://drive.uc.cn/list#/list/all/14f5cdfeba414f45993cee00feb5ee7e-Agent%20MCP',
    folderFid: '14f5cdfeba414f45993cee00feb5ee7e',
    selectors: [
      'input#ListHeader-file',
      'input[type="file"]:not([webkitdirectory])',
    ],
  },
  {
    key: '139',
    name: '中国移动云盘 (139)',
    matchUrl: (u) => u.includes('yun.139.com/w/'),
    targetUrl: 'https://yun.139.com/w/#/index',
    selectors: [
      'input#UploadFileBtn',
      'input#UploadFileBtn01',
      'input#mainInput',
      'input[type="file"]:not([webkitdirectory])',
    ],
  },
];

function getJson(urlPath) {
  return new Promise((resolve, reject) => {
    const req = http.get({ host: CDP_HOST, port: CDP_PORT, path: urlPath, timeout: 8000 }, (res) => {
      let data = '';
      res.on('data', (chunk) => (data += chunk));
      res.on('end', () => {
        try {
          resolve(JSON.parse(data));
        } catch (err) {
          reject(new Error(`Invalid JSON from ${urlPath}: ${data.slice(0, 200)}`));
        }
      });
    });
    req.on('error', reject);
    req.on('timeout', () => {
      req.destroy(new Error(`Timeout connecting to ${CDP_HOST}:${CDP_PORT}${urlPath}`));
    });
  });
}

class CdpClient {
  constructor(wsUrl) {
    this.wsUrl = wsUrl;
    this.ws = null;
    this.seq = 0;
    this.pending = new Map();
    this.listeners = new Map();
  }

  async connect() {
    const WS = globalThis.WebSocket;
    if (!WS) {
      throw new Error('Node global WebSocket unavailable (requires Node 21+).');
    }
    await new Promise((resolve, reject) => {
      const ws = new WS(this.wsUrl);
      this.ws = ws;
      const timer = setTimeout(() => reject(new Error(`WS connect timeout: ${this.wsUrl}`)), 8000);
      ws.addEventListener('open', () => {
        clearTimeout(timer);
        resolve();
      });
      ws.addEventListener('error', (ev) => {
        clearTimeout(timer);
        reject(new Error(`WS error on ${this.wsUrl}: ${ev.message || 'unknown'}`));
      });
      ws.addEventListener('message', (ev) => {
        const raw = typeof ev.data === 'string' ? ev.data : Buffer.from(ev.data).toString('utf8');
        let msg;
        try {
          msg = JSON.parse(raw);
        } catch {
          return;
        }
        if (msg.id && this.pending.has(msg.id)) {
          const { resolve: res, reject: rej, timer: t } = this.pending.get(msg.id);
          clearTimeout(t);
          this.pending.delete(msg.id);
          if (msg.error) {
            rej(new Error(`CDP error (${msg.error.code}): ${msg.error.message}`));
          } else {
            res(msg.result);
          }
        } else if (msg.method && this.listeners.has(msg.method)) {
          for (const cb of this.listeners.get(msg.method)) {
            cb(msg.params || {});
          }
        }
      });
    });
  }

  on(method, cb) {
    if (!this.listeners.has(method)) this.listeners.set(method, []);
    this.listeners.get(method).push(cb);
  }

  send(method, params = {}, timeoutMs = 15000) {
    return new Promise((resolve, reject) => {
      const id = ++this.seq;
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`CDP timeout on ${method}`));
      }, timeoutMs);
      this.pending.set(id, { resolve, reject, timer });
      this.ws.send(JSON.stringify({ id, method, params }));
    });
  }

  close() {
    if (this.ws) {
      try {
        this.ws.close();
      } catch {}
    }
  }
}

async function fetchServerFiles(cdp, drive) {
  if (drive.key === 'quark') {
    const expr = `(async () => {
      const r = await fetch('https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&pdir_fid=${drive.folderFid}&_page=1&_size=100&_fetch_total=1', { credentials: 'include' });
      const j = await r.json();
      const list = (j.data && j.data.list) || [];
      // Clean up accidental (1) duplicates automatically
      const dupes = list.filter(x => /\\(\\d+\\)\\.(gz|zip|exe|apk|dmg|txt)$/i.test(x.file_name));
      if (dupes.length > 0) {
        await fetch('https://drive-pc.quark.cn/1/clouddrive/file/delete?pr=ucpro&fr=pc', {
          method: 'POST',
          credentials: 'include',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action_type: 2, filelist: dupes.map(d => d.fid), exclude_fids: [] })
        });
      }
      return list.filter(x => !dupes.some(d => d.fid === x.fid)).map(x => x.file_name).sort();
    })()`;
    const r = await cdp.send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
    return r.result.value || [];
  }
  if (drive.key === 'baidu') {
    const expr = `(async () => {
      const r = await fetch('/api/list?dir=%2FAgent%20MCP&num=100&page=1&order=name&web=1', { credentials: 'include' });
      const j = await r.json();
      return ((j.list) || []).map(x => x.server_filename).sort();
    })()`;
    const r = await cdp.send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
    return r.result.value || [];
  }
  if (drive.key === 'uc') {
    const expr = `(async () => {
      const r = await fetch('https://pc-api.uc.cn/1/clouddrive/file/sort?pr=UCBrowser&fr=pc&pdir_fid=${drive.folderFid}&_page=1&_size=100&_fetch_total=1', { credentials: 'include' });
      const j = await r.json();
      return ((j.data && j.data.list) || []).map(x => x.file_name).sort();
    })()`;
    const r = await cdp.send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true });
    return r.result.value || [];
  }
  return null;
}

async function inspectDrivePage(cdp, drive) {
  await cdp.send('DOM.enable');
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  const expr = `(() => {
    const inputs = Array.from(document.querySelectorAll('input[type="file"]')).map((el, idx) => ({
      idx,
      id: el.id || '',
      name: el.name || '',
      multiple: !!el.multiple,
      webkitdirectory: el.hasAttribute('webkitdirectory'),
      accept: el.getAttribute('accept') || '',
    }));
    const bodyText = (document.body ? document.body.innerText : '') || '';
    const agentMcpMentions = bodyText.includes('Agent MCP');
    const domFiles = Array.from(new Set(
      (bodyText.match(/AgentMCP-[\\w.-]+|SHA256SUMS\\.txt/g) || [])
    )).sort();
    const progressMatches = Array.from(new Set(
      (bodyText.match(/(?:上传中|正在上传|上传完成|秒传|已完成|传输列表\\s*\\d*|共\\s*\\d+\\s*项|\\d+(?:\\.\\d+)?%|\\d+\\/\\d+)/g) || [])
    )).slice(0, 20);
    const isLoggedOut =
      (location.hostname === 'drive.uc.cn' && location.pathname === '/') ||
      bodyText.includes('微信扫码') ||
      bodyText.includes('扫码登录');
    return {
      href: location.href,
      title: document.title,
      loggedIn: !isLoggedOut,
      inAgentMcp: !isLoggedOut && (agentMcpMentions || decodeURIComponent(location.href).includes('Agent MCP')),
      inputs,
      domFiles,
      progressMatches,
    };
  })()`;
  const evalRes = await cdp.send('Runtime.evaluate', { expression: expr, returnByValue: true });
  const info = evalRes.result.value;
  try {
    const srvFiles = await fetchServerFiles(cdp, drive);
    info.serverFiles = srvFiles || info.domFiles;
  } catch {
    info.serverFiles = info.domFiles;
  }
  return info;
}

async function resolveFileInputObjectId(cdp, selectors) {
  const selJson = JSON.stringify(selectors);
  const expr = `(() => {
    const selectors = ${selJson};
    for (const s of selectors) {
      const el = document.querySelector(s);
      if (el) return el;
    }
    const all = Array.from(document.querySelectorAll('input[type="file"]'));
    return all.find(el => !el.hasAttribute('webkitdirectory') && !String(el.getAttribute('accept') || '').includes('image/') && el.getAttribute('accept') !== '.torrent') || null;
  })()`;
  const res = await cdp.send('Runtime.evaluate', { expression: expr, returnByValue: false });
  if (!res.result || !res.result.objectId) {
    return null;
  }
  return res.result.objectId;
}

async function injectViaChooserOrPaste(cdp, files) {
  // Strategy 2: Intercept dynamic detached <input type="file"> when clicking "上传文件"
  await cdp.send('Page.bringToFront');
  await cdp.send('Page.setInterceptFileChooserDialog', { enabled: true });
  let chooserParams = null;
  cdp.on('Page.fileChooserOpened', (params) => {
    chooserParams = params;
  });

  await cdp.send('Runtime.evaluate', {
    expression: `(() => {
      const candidates = Array.from(document.querySelectorAll('button, span, a, div'));
      const btn = candidates.find(el => el.children.length === 0 && (el.textContent || '').trim() === '上传文件');
      if (btn) {
        btn.click();
        return 'clicked_upload_btn';
      }
      return 'no_btn';
    })()`,
    returnByValue: true,
  });

  for (let i = 0; i < 15 && !chooserParams; i++) {
    await new Promise((r) => setTimeout(r, 150));
  }

  try {
    await cdp.send('Page.setInterceptFileChooserDialog', { enabled: false });
  } catch {}

  if (chooserParams && chooserParams.backendNodeId) {
    await cdp.send('DOM.setFileInputFiles', {
      backendNodeId: chooserParams.backendNodeId,
      files,
    });
    return 'fileChooser(backendNodeId)';
  }

  // Strategy 3: Put files onto Windows Explorer Clipboard (CF_HDROP) & dispatch native Paste onto dropzone
  const psPaths = files.map((f) => `'${f.replace(/'/g, "''")}'`).join(',');
  spawnSync('powershell.exe', ['-NoProfile', '-Command', `Set-Clipboard -Path @(${psPaths})`], { stdio: 'ignore' });
  await cdp.send('Runtime.evaluate', {
    expression: `(() => {
      const candidates = Array.from(document.querySelectorAll('div'));
      const dz = candidates.find(el => (el.textContent || '').includes('拖拽/粘贴')) || document.body;
      dz.focus && dz.focus();
    })()`,
  });
  await cdp.send('Input.dispatchKeyEvent', {
    type: 'keyDown',
    modifiers: 2,
    windowsVirtualKeyCode: 86,
    code: 'KeyV',
    key: 'v',
    commands: ['Paste'],
  });
  await cdp.send('Input.dispatchKeyEvent', {
    type: 'keyUp',
    modifiers: 2,
    windowsVirtualKeyCode: 86,
    code: 'KeyV',
    key: 'v',
  });
  return 'clipboardPaste(Ctrl+V)';
}

async function openNewDriveTab(targetUrl) {
  const ver = await getJson('/json/version');
  const browserCdp = new CdpClient(ver.webSocketDebuggerUrl);
  try {
    await browserCdp.connect();
    const { targetId } = await browserCdp.send('Target.createTarget', { url: targetUrl });
    await new Promise((r) => setTimeout(r, 4500));
    const refreshed = await getJson('/json');
    return refreshed.find((t) => t.targetId === targetId || t.id === targetId) || null;
  } finally {
    browserCdp.close();
  }
}

function parseArgs(argv) {
  const opts = {
    status: false,
    refresh: false,
    tag: 'v3.5.7',
    drives: null,
    only: null,
    skipExisting: true,
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--status') opts.status = true;
    else if (a === '--refresh') opts.refresh = true;
    else if (a === '--no-skip-existing') opts.skipExisting = false;
    else if (a === '--tag' && argv[i + 1]) opts.tag = argv[++i];
    else if (a === '--drives' && argv[i + 1]) opts.drives = argv[++i].split(',').map((s) => s.trim());
    else if (a === '--only' && argv[i + 1]) opts.only = argv[++i].split(',').map((s) => s.trim());
  }
  return opts;
}

async function main() {
  const opts = parseArgs(process.argv);
  const repoRoot = path.resolve(__dirname, '..');
  const stageDir = path.join(repoRoot, 'cloud_drive_upload', opts.tag);

  const targets = await getJson('/json');
  const pages = targets.filter((t) => t.type === 'page' && t.webSocketDebuggerUrl);

  const activeDrives = opts.drives
    ? DRIVES.filter((d) => opts.drives.includes(d.key))
    : DRIVES;

  let localFiles = [];
  if (!opts.status) {
    if (!fs.existsSync(stageDir)) {
      throw new Error(`Staging directory does not exist: ${stageDir}`);
    }
    localFiles = fs
      .readdirSync(stageDir)
      .filter((f) => !f.startsWith('.') && f !== 'SHA256SUMS.txt')
      .filter((f) => (!opts.only ? true : opts.only.includes(f)))
      .sort()
      .map((f) => path.join(stageDir, f));
    console.log(`[Stage] ${localFiles.length} local file(s) ready in ${stageDir}`);
  }

  for (const drive of activeDrives) {
    let page = pages.find((p) => drive.matchUrl(p.url || ''));
    if (!page && drive.targetUrl) {
      console.log(`\n[${drive.key}] Opening new tab -> ${drive.targetUrl} ...`);
      page = await openNewDriveTab(drive.targetUrl);
    }
    if (!page) {
      console.log(`\n[${drive.key}] ${drive.name}: TAB NOT FOUND`);
      continue;
    }
    const cdp = new CdpClient(page.webSocketDebuggerUrl);
    try {
      await cdp.connect();
      if (opts.refresh) {
        await cdp.send('Page.enable');
        await cdp.send('Page.reload', { ignoreCache: true });
        await new Promise((r) => setTimeout(r, 4500));
        if (drive.key === '139') {
          await cdp.send('Runtime.enable');
          await cdp.send('Runtime.evaluate', {
            expression: `(() => {
              const items = Array.from(document.querySelectorAll('span, a, div'));
              const folder = items.find(el => el.children.length === 0 && (el.textContent || '').trim() === 'Agent MCP');
              if (folder) {
                folder.click();
                folder.dispatchEvent(new MouseEvent('dblclick', { bubbles: true }));
              }
            })()`,
          });
          await new Promise((r) => setTimeout(r, 3000));
          await cdp.send('Runtime.evaluate', {
            expression: `(() => {
              document.querySelectorAll('div').forEach(d => {
                if (d.scrollHeight > d.clientHeight + 50) d.scrollTop = d.scrollHeight;
              });
            })()`,
          });
          await new Promise((r) => setTimeout(r, 1000));
        }
      }
      let info = await inspectDrivePage(cdp, drive);
      if (!info.inAgentMcp && drive.targetUrl) {
        await cdp.send('Page.navigate', { url: drive.targetUrl });
        await new Promise((r) => setTimeout(r, 3500));
        info = await inspectDrivePage(cdp, drive);
      }
      console.log(`\n[${drive.key}] ${drive.name}`);
      console.log(`  URL: ${info.href}`);
      console.log(`  loggedIn: ${info.loggedIn} | inAgentMcp: ${info.inAgentMcp} | inputs: ${info.inputs.length}`);
      console.log(`  Server/Folder files (${info.serverFiles.length}): ${info.serverFiles.join(', ') || '(none)'}`);
      console.log(`  Progress/Status: ${info.progressMatches.join(' | ') || '(none)'}`);

      if (opts.status) continue;

      if (!info.inAgentMcp) {
        console.log(`  WARNING: Not inside 'Agent MCP' folder (or login required). Skipping ${drive.key}.`);
        continue;
      }

      let toUpload = localFiles;
      if (opts.skipExisting && info.serverFiles.length > 0) {
        const existingSet = new Set(info.serverFiles);
        toUpload = localFiles.filter((fp) => {
          const base = path.basename(fp);
          if (opts.only && opts.only.includes(base)) return true;
          return !existingSet.has(base);
        });
      }

      if (toUpload.length === 0) {
        console.log(`  All ${localFiles.length} file(s) already present in ${drive.name}!`);
        continue;
      }

      const objectId = await resolveFileInputObjectId(cdp, drive.selectors);
      if (objectId) {
        await cdp.send('DOM.setFileInputFiles', {
          objectId,
          files: toUpload,
        });
        console.log(`  UPLOAD TRIGGERED via DOM input (${toUpload.length} files): ${toUpload.map((f) => path.basename(f)).join(', ')}`);
      } else {
        const methodUsed = await injectViaChooserOrPaste(cdp, toUpload);
        console.log(`  UPLOAD TRIGGERED via ${methodUsed} (${toUpload.length} files): ${toUpload.map((f) => path.basename(f)).join(', ')}`);
      }
    } finally {
      cdp.close();
    }
  }
}

main().catch((err) => {
  console.error('FATAL:', err.message || err);
  process.exit(1);
});
