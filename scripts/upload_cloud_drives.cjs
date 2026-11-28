#!/usr/bin/env node
/**
 * Automated 4-Cloud-Drive Structured Folder Uploader & Verifier for Agent MCP via CDP.
 *
 * Follows the user-established golden workflow:
 *   1. Open the target `Agent MCP` folder directly in the logged-in Edge browser (:9222).
 *   2. Organize only the 18 formal release packages (excluding `SHA256SUMS.txt`) into
 *      `windows/`, `macos/`, `linux/`, `android/` -> `x64/`, `arm64/`, etc.
 *   3. Upload via native `<input type="file" webkitdirectory>` or native Windows Explorer
 *      Clipboard (`Set-Clipboard -Path`) + `Ctrl+V` paste onto the dropzone.
 *   4. Always hard-refresh (`Page.reload({ ignoreCache: true })`) all 4 tabs at the end
 *      and recursively verify all 18 persisted files across the OS/arch subfolders.
 *
 * Usage:
 *   node scripts/upload_cloud_drives.cjs --status --refresh
 *   node scripts/upload_cloud_drives.cjs --tag v3.5.8 --clean-old
 *   node scripts/upload_cloud_drives.cjs --tag v3.5.8 --drives quark,baidu,uc,139
 */

const fs = require('fs');
const path = require('path');
const http = require('http');
const { spawnSync } = require('child_process');

const CDP_HOST = process.env.CDP_HOST || '127.0.0.1';
const CDP_PORT = Number(process.env.CDP_PORT || 9222);
const EXPECTED_OS_DIRS = ['windows', 'macos', 'linux', 'android'];

const DRIVES = [
  {
    key: 'quark',
    name: '夸克网盘 (Quark)',
    matchUrl: (u) => u.includes('pan.quark.cn'),
    targetUrl: 'https://pan.quark.cn/list#/list/all/c848ce6b47214b9aa0815dd76f557477-Agent%20MCP',
    folderFid: 'c848ce6b47214b9aa0815dd76f557477',
    hoverUploadMenu: true,
    dirSelector: 'input#ListHeader-list-doc[webkitdirectory], input[type="file"][webkitdirectory]',
    fileSelectors: [
      'input#ListHeader-file',
      'input[type="file"]:not([webkitdirectory])',
    ],
  },
  {
    key: 'baidu',
    name: '百度网盘 (Baidu)',
    matchUrl: (u) => u.includes('pan.baidu.com'),
    targetUrl: 'https://pan.baidu.com/disk/main#/index?category=all&path=%2FAgent%20MCP',
    dirSelector: 'input[type="file"][name="html5uploader"][webkitdirectory]',
    fileSelectors: [
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
    hoverUploadMenu: true,
    dirSelector: 'input#ListHeader-list-doc[webkitdirectory], input[type="file"][webkitdirectory]',
    fileSelectors: [
      'input#ListHeader-file',
      'input[type="file"]:not([webkitdirectory])',
    ],
  },
  {
    key: '139',
    name: '中国移动云盘 (139)',
    matchUrl: (u) => u.includes('yun.139.com/w/'),
    targetUrl: 'https://yun.139.com/w/#/index',
    dirSelector: 'input#UploadFileBtn02[webkitdirectory]',
    fileSelectors: [
      'input#UploadFileBtn',
      'input#UploadFileBtn01',
      'input#mainInput',
      'input[type="file"]:not([webkitdirectory])',
    ],
  },
];

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

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

  send(method, params = {}, timeoutMs = 20000) {
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

async function get139Breadcrumb(cdp) {
  const res = await cdp.send('Runtime.evaluate', {
    returnByValue: true,
    expression: `(() => {
      const root = document.querySelector('.document_title');
      if (!root) return [];
      return Array.from(root.querySelectorAll('.document_title_item_text, .document_title_item_text_all'))
        .filter(el => el.getBoundingClientRect().width > 0)
        .map(el => (el.getAttribute('title') || el.textContent || '').trim())
        .filter(Boolean)
        .filter((v, i, a) => i === 0 || v !== a[i - 1]);
    })()`,
  });
  return (res.result && res.result.value) || [];
}

async function click139Breadcrumb(cdp, titleText) {
  for (let attempt = 0; attempt < 8; attempt++) {
    const crumbs = await get139Breadcrumb(cdp);
    if (crumbs[crumbs.length - 1] === titleText) return true;
    const pos = await cdp.send('Runtime.evaluate', {
      returnByValue: true,
      expression: `(() => {
        const el = Array.from(document.querySelectorAll('.document_title .document_title_item_text, .document_title .document_title_item_text_all'))
          .find(e => e.getBoundingClientRect().width > 0 && ((e.getAttribute('title') || e.textContent || '').trim() === ${JSON.stringify(titleText)}));
        if (!el) return null;
        const r = el.getBoundingClientRect();
        return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
      })()`,
    });
    const pt = pos.result && pos.result.value;
    if (pt) {
      await cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: pt.x, y: pt.y });
      await sleep(120);
      await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: pt.x, y: pt.y, button: 'left', clickCount: 1 });
      await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: pt.x, y: pt.y, button: 'left', clickCount: 1 });
      for (let w = 0; w < 8; w++) {
        await sleep(500);
        const after = await get139Breadcrumb(cdp);
        if (after[after.length - 1] === titleText) return true;
      }
    } else {
      await sleep(500);
    }
  }
  return false;
}

async function click139TableFolder(cdp, folderName) {
  for (let attempt = 0; attempt < 10; attempt++) {
    const crumbs = await get139Breadcrumb(cdp);
    if (crumbs[crumbs.length - 1] === folderName) return true;
    const pos = await cdp.send('Runtime.evaluate', {
      returnByValue: true,
      expression: `(() => {
        const el = Array.from(document.querySelectorAll('span, a, div'))
          .find(e => {
            if (e.closest('.document_title') || e.children.length !== 0) return false;
            if ((e.textContent || '').trim() !== ${JSON.stringify(folderName)}) return false;
            const r = e.getBoundingClientRect();
            return r.width > 0 && r.height > 0 && r.left > 180 && r.left < 750 && r.top > 155;
          });
        if (!el) return null;
        const r = e.getBoundingClientRect();
        return { x: Math.round(r.left + r.width / 2), y: Math.round(r.top + r.height / 2) };
      })()`,
    });
    const pt = pos.result && pos.result.value;
    if (!pt) {
      await sleep(600);
      continue;
    }
    await cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x: pt.x, y: pt.y });
    await sleep(120);
    await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', x: pt.x, y: pt.y, button: 'left', clickCount: 1 });
    await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x: pt.x, y: pt.y, button: 'left', clickCount: 1 });
    for (let w = 0; w < 8; w++) {
      await sleep(500);
      const after = await get139Breadcrumb(cdp);
      if (after[after.length - 1] === folderName) {
        await sleep(600); // allow file list rows inside target folder to settle
        return true;
      }
    }
  }
  return false;
}

async function list139MainTableEntries(cdp) {
  const res = await cdp.send('Runtime.evaluate', {
    returnByValue: true,
    expression: `(() => {
      const osSet = new Set(['windows', 'macos', 'linux', 'android', 'x64', 'arm64', 'arm64-v8a', 'armeabi-v7a', 'x86_64', 'universal']);
      const dirs = new Set();
      const files = new Set();
      for (const e of document.querySelectorAll('span, a, div')) {
        if (e.closest('.document_title') || e.children.length !== 0) continue;
        const r = e.getBoundingClientRect();
        if (r.width <= 0 || r.height <= 0 || r.left <= 180 || r.left >= 750 || r.top <= 155) continue;
        const t = (e.textContent || '').trim();
        if (!t) continue;
        if (osSet.has(t)) dirs.add(t);
        else if (/^AgentMCP-[\\w.-]+$|^SHA256SUMS\\.txt$/.test(t)) files.add(t);
      }
      return { dirs: Array.from(dirs).sort(), files: Array.from(files).sort() };
    })()`,
  });
  return (res.result && res.result.value) || { dirs: [], files: [] };
}

async function enter139AgentMcpFolder(cdp) {
  await cdp.send('Runtime.enable');
  let crumbs = await get139Breadcrumb(cdp);
  if (crumbs.length === 2 && crumbs[0] === '全部' && crumbs[1] === 'Agent MCP') {
    return true;
  }
  if (crumbs.includes('Agent MCP')) {
    await click139Breadcrumb(cdp, 'Agent MCP');
    crumbs = await get139Breadcrumb(cdp);
    if (crumbs.length === 2 && crumbs[1] === 'Agent MCP') return true;
  }
  if (crumbs.length !== 1 || crumbs[0] !== '全部') {
    await click139Breadcrumb(cdp, '全部');
  }
  await click139TableFolder(cdp, 'Agent MCP');
  crumbs = await get139Breadcrumb(cdp);
  return crumbs.length === 2 && crumbs[0] === '全部' && crumbs[1] === 'Agent MCP';
}

async function fetchRecursiveTree(cdp, drive) {
  if (drive.key === 'quark' || drive.key === 'uc') {
    const apiBase = drive.key === 'quark'
      ? 'https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc'
      : 'https://pc-api.uc.cn/1/clouddrive/file/sort?pr=UCBrowser&fr=pc';
    const expr = `(async () => {
      async function walk(fid, prefix) {
        const r = await fetch('${apiBase}&pdir_fid=' + fid + '&_page=1&_size=100&_fetch_total=1', { credentials: 'include' });
        const j = await r.json();
        const list = (j.data && j.data.list) || [];
        const files = [];
        const topEntries = prefix === '' ? list.map(x => ({ name: x.file_name, dir: !!x.dir, fid: x.fid })) : [];
        for (const item of list) {
          const rel = prefix ? prefix + '/' + item.file_name : item.file_name;
          if (item.dir) {
            const sub = await walk(item.fid, rel);
            files.push(...sub.files);
          } else {
            files.push(rel);
          }
        }
        return { topEntries, files };
      }
      return await walk('${drive.folderFid}', '');
    })()`;
    const r = await cdp.send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }, 30000);
    return r.result.value || { topEntries: [], files: [] };
  }

  if (drive.key === 'baidu') {
    const expr = `(async () => {
      async function walk(dirPath, prefix) {
        const r = await fetch('/api/list?dir=' + encodeURIComponent(dirPath) + '&num=100&page=1&order=name&web=1', { credentials: 'include' });
        const j = await r.json();
        const list = j.list || [];
        const files = [];
        const topEntries = prefix === '' ? list.map(x => ({ name: x.server_filename, dir: x.isdir === 1, path: x.path })) : [];
        for (const item of list) {
          const rel = prefix ? prefix + '/' + item.server_filename : item.server_filename;
          if (item.isdir === 1) {
            const sub = await walk(item.path, rel);
            files.push(...sub.files);
          } else {
            files.push(rel);
          }
        }
        return { topEntries, files };
      }
      return await walk('/Agent MCP', '');
    })()`;
    const r = await cdp.send('Runtime.evaluate', { expression: expr, awaitPromise: true, returnByValue: true }, 30000);
    return r.result.value || { topEntries: [], files: [] };
  }

  if (drive.key === '139') {
    const inFolder = await enter139AgentMcpFolder(cdp);
    if (!inFolder) return { topEntries: [], files: [] };
    const topTbl = await list139MainTableEntries(cdp);
    const osDirs = topTbl.dirs.filter((d) => EXPECTED_OS_DIRS.includes(d));
    const flatFiles = topTbl.files;
    const topEntries = [
      ...osDirs.map((d) => ({ name: d, dir: true })),
      ...flatFiles.map((f) => ({ name: f, dir: false })),
    ];
    if (osDirs.length === 0) {
      return { topEntries, files: flatFiles };
    }

    const allFiles = [...flatFiles];
    for (const osName of osDirs) {
      await enter139AgentMcpFolder(cdp);
      const enteredOs = await click139TableFolder(cdp, osName);
      if (!enteredOs) continue;
      const osTbl = await list139MainTableEntries(cdp);
      for (const archName of osTbl.dirs) {
        const enteredArch = await click139TableFolder(cdp, archName);
        if (!enteredArch) continue;
        const archTbl = await list139MainTableEntries(cdp);
        for (const lf of archTbl.files) {
          allFiles.push(`${osName}/${archName}/${lf}`);
        }
        await click139Breadcrumb(cdp, osName);
      }
      await enter139AgentMcpFolder(cdp);
    }
    return { topEntries, files: allFiles.sort() };
  }

  return { topEntries: [], files: [] };
}

async function cleanExistingEntriesInAgentMcp(cdp, drive) {
  if (drive.key === 'quark' || drive.key === 'uc') {
    const sortUrl = drive.key === 'quark'
      ? `https://drive-pc.quark.cn/1/clouddrive/file/sort?pr=ucpro&fr=pc&pdir_fid=${drive.folderFid}&_page=1&_size=100`
      : `https://pc-api.uc.cn/1/clouddrive/file/sort?pr=UCBrowser&fr=pc&pdir_fid=${drive.folderFid}&_page=1&_size=100`;
    const delUrl = drive.key === 'quark'
      ? 'https://drive-pc.quark.cn/1/clouddrive/file/delete?pr=ucpro&fr=pc'
      : 'https://pc-api.uc.cn/1/clouddrive/file/delete?pr=UCBrowser&fr=pc';
    const res = await cdp.send('Runtime.evaluate', {
      awaitPromise: true,
      returnByValue: true,
      expression: `(async () => {
        const r = await fetch('${sortUrl}', { credentials: 'include' });
        const j = await r.json();
        const list = (j.data && j.data.list) || [];
        if (list.length === 0) return 0;
        await fetch('${delUrl}', {
          method: 'POST',
          credentials: 'include',
          headers: { 'Content-Type': 'application/json' },
          body: JSON.stringify({ action_type: 2, filelist: list.map(x => x.fid), exclude_fids: [] })
        });
        return list.length;
      })()`,
    });
    await sleep(1500);
    await cdp.send('Page.reload', { ignoreCache: true });
    await sleep(3500);
    return (res.result && res.result.value) || 0;
  }

  if (drive.key === 'baidu') {
    const res = await cdp.send('Runtime.evaluate', {
      awaitPromise: true,
      returnByValue: true,
      expression: `(async () => {
        const lr = await fetch('/api/list?dir=%2FAgent%20MCP&num=100&page=1&order=name&web=1', { credentials: 'include' });
        const lj = await lr.json();
        const list = lj.list || [];
        if (list.length === 0) return 0;
        let bdstoken = (window.locals && window.locals.get && window.locals.get('bdstoken')) || (window.yunData && window.yunData.MYBDSTOKEN) || '';
        if (!bdstoken) {
          const tr = await fetch('/api/gettemplatevariable?fields=%5B%22bdstoken%22%5D&web=1', { credentials: 'include' });
          const tj = await tr.json();
          bdstoken = (tj.result && tj.result.bdstoken) || '';
        }
        const paths = list.map(x => x.path).filter(p => p.startsWith('/Agent MCP/'));
        if (paths.length === 0) return 0;
        const body = 'filelist=' + encodeURIComponent(JSON.stringify(paths));
        await fetch('/api/filemanager?opera=delete&async=2&onnest=fail&channel=chunlei&web=1&bdstoken=' + encodeURIComponent(bdstoken), {
          method: 'POST',
          credentials: 'include',
          headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' },
          body
        });
        return paths.length;
      })()`,
    });
    await sleep(2500);
    await cdp.send('Page.reload', { ignoreCache: true });
    await sleep(4000);
    return (res.result && res.result.value) || 0;
  }

  if (drive.key === '139') {
    const okIn = await enter139AgentMcpFolder(cdp);
    if (!okIn) {
      throw new Error('Safety stop: 139 tab is NOT confirmed inside Agent MCP breadcrumb!');
    }
    const crumbs = await get139Breadcrumb(cdp);
    if (crumbs.length !== 2 || crumbs[1] !== 'Agent MCP') {
      throw new Error(`Safety stop: unexpected 139 breadcrumb: ${crumbs.join(' > ')}`);
    }
    // Select-all checkbox in table header inside Agent MCP + click 删除 + confirm 确定
    const clicked = await cdp.send('Runtime.evaluate', {
      returnByValue: true,
      expression: `(() => {
        const txt = (document.body ? document.body.innerText : '') || '';
        if (txt.includes('暂无文件') || txt.includes('空空如也')) return 'ALREADY_EMPTY';
        const rowChecks = document.querySelectorAll('div.document_table_list_check');
        if (!rowChecks || rowChecks.length === 0) return 'ALREADY_EMPTY';
        const hdrCb = document.querySelector('div.item-0.checkbox');
        if (!hdrCb) return 'NO_CHECKBOX';
        hdrCb.click();
        return 'CHECKED';
      })()`,
    });
    const status = clicked.result && clicked.result.value;
    if (status === 'CHECKED') {
      await sleep(1000);
      await cdp.send('Runtime.evaluate', {
        returnByValue: true,
        expression: `(() => {
          const delBtn = Array.from(document.querySelectorAll('button, span, a, div, li'))
            .find(el => el.children.length === 0 && (el.textContent || '').trim() === '删除' && el.offsetParent !== null);
          if (delBtn) { delBtn.click(); return true; }
          return false;
        })()`,
      });
      await sleep(1200);
      await cdp.send('Runtime.evaluate', {
        returnByValue: true,
        expression: `(() => {
          const okBtn = Array.from(document.querySelectorAll('button, span, div'))
            .filter(el => el.children.length === 0 && ['确定', '确认', '删除', '移入回收站'].includes((el.textContent || '').trim()) && el.offsetParent !== null)
            .pop();
          if (okBtn) { okBtn.click(); return (okBtn.textContent || '').trim(); }
          return null;
        })()`,
      });
      await sleep(3800);
      return 18;
    }
    return 0;
  }

  return 0;
}

async function pasteDirectoriesViaClipboard(cdp, dirPaths) {
  await cdp.send('Page.bringToFront');
  const psPaths = dirPaths.map((f) => `'${f.replace(/'/g, "''")}'`).join(',');
  spawnSync('powershell.exe', ['-NoProfile', '-Command', `Set-Clipboard -Path @(${psPaths})`], { stdio: 'ignore' });
  await cdp.send('Runtime.evaluate', {
    expression: `(() => {
      const candidates = Array.from(document.querySelectorAll('div'));
      const dz = candidates.find(el => (el.textContent || '').includes('拖拽') || (el.textContent || '').includes('粘贴')) || document.body;
      if (dz && dz.focus) dz.focus();
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
  return 'clipboardPaste(Ctrl+V folders)';
}

async function uploadStructuredFolders(cdp, drive, osDirPaths, methodPref = 'auto') {
  await cdp.send('DOM.enable');
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');

  // 1. Quark: Native Windows Clipboard folder paste (Ctrl+V) onto dropzone
  if (drive.key === 'quark' || methodPref === 'paste') {
    return await pasteDirectoriesViaClipboard(cdp, osDirPaths);
  }

  // 2. Baidu: Create <os>/<arch> subfolders cleanly inside /Agent MCP + feed native <input type="file">
  if (drive.key === 'baidu') {
    const subdirs = [];
    for (const osDir of osDirPaths) {
      const osName = path.basename(osDir);
      for (const archName of fs.readdirSync(osDir)) {
        const fullArch = path.join(osDir, archName);
        if (fs.statSync(fullArch).isDirectory()) {
          subdirs.push({ rel: `${osName}/${archName}`, localDir: fullArch });
        }
      }
    }
    await cdp.send('Runtime.evaluate', {
      awaitPromise: true,
      returnByValue: true,
      expression: `(async () => {
        let bdstoken = (window.locals && window.locals.get && window.locals.get('bdstoken')) || (window.yunData && window.yunData.MYBDSTOKEN) || '';
        if (!bdstoken) {
          const tr = await fetch('/api/gettemplatevariable?fields=%5B%22bdstoken%22%5D&web=1', { credentials: 'include' });
          const tj = await tr.json();
          bdstoken = (tj.result && tj.result.bdstoken) || '';
        }
        async function mkdir(remotePath) {
          const body = 'path=' + encodeURIComponent(remotePath) + '&isdir=1&block_list=%5B%5D';
          await fetch('/api/create?a=commit&channel=chunlei&web=1&bdstoken=' + encodeURIComponent(bdstoken), {
            method: 'POST',
            credentials: 'include',
            headers: { 'Content-Type': 'application/x-www-form-urlencoded; charset=UTF-8' },
            body,
          });
        }
        for (const osName of ${JSON.stringify(osDirPaths.map((p) => path.basename(p)))}) {
          await mkdir('/Agent MCP/' + osName);
        }
        for (const rel of ${JSON.stringify(subdirs.map((s) => s.rel))}) {
          await mkdir('/Agent MCP/' + rel);
        }
      })()`,
    });
    for (const { rel, localDir } of subdirs) {
      const files = fs.readdirSync(localDir).map((f) => path.join(localDir, f)).filter((p) => fs.statSync(p).isFile());
      const targetHashUrl = 'https://pan.baidu.com/disk/main#/index?category=all&path=' + encodeURIComponent('/Agent MCP/' + rel);
      await cdp.send('Runtime.evaluate', { expression: `location.href = ${JSON.stringify(targetHashUrl)}` });
      await sleep(2000);
      const inp = await cdp.send('Runtime.evaluate', {
        returnByValue: false,
        expression: `document.querySelector('input[type="file"][name="html5uploader"]:not([webkitdirectory]):not([accept=".torrent"])')`,
      });
      if (inp.result && inp.result.objectId) {
        await cdp.send('DOM.setFileInputFiles', { objectId: inp.result.objectId, files });
      }
      await sleep(1800);
    }
    await cdp.send('Runtime.evaluate', {
      expression: `location.href = 'https://pan.baidu.com/disk/main#/index?category=all&path=%2FAgent%20MCP'`,
    });
    await sleep(1500);
    return `baiduSubfolderFileInput(${subdirs.length} subfolders)`;
  }

  // 3. China Mobile 139: Create folder skeleton via UploadFileBtn02 chooser + populate each <os>/<arch> via UploadFileBtn
  if (drive.key === '139') {
    const okIn = await enter139AgentMcpFolder(cdp);
    if (!okIn) throw new Error('139 tab is not inside Agent MCP folder!');

    // Ensure top-level + arch folder skeleton exists via UploadFileBtn02 fileChooser intercept if missing
    const existingTop = await list139MainTableEntries(cdp);
    const missingOsDirs = osDirPaths.filter((p) => !existingTop.dirs.includes(path.basename(p)));
    if (missingOsDirs.length > 0) {
      await cdp.send('Page.setInterceptFileChooserDialog', { enabled: true });
      for (const dirPath of missingOsDirs) {
        const fcPromise = new Promise((resolve) => {
          const timer = setTimeout(() => resolve(null), 3500);
          const handler = (params) => {
            clearTimeout(timer);
            const arr = cdp.listeners.get('Page.fileChooserOpened') || [];
            const idx = arr.indexOf(handler);
            if (idx >= 0) arr.splice(idx, 1);
            resolve(params);
          };
          cdp.on('Page.fileChooserOpened', handler);
        });
        await cdp.send('Runtime.evaluate', {
          userGesture: true,
          expression: `document.querySelector('input#UploadFileBtn02') && document.querySelector('input#UploadFileBtn02').click()`,
        });
        const fc = await fcPromise;
        if (fc && fc.backendNodeId) {
          await cdp.send('DOM.setFileInputFiles', { backendNodeId: fc.backendNodeId, files: [dirPath] });
        }
        await sleep(2800);
      }
      await cdp.send('Page.setInterceptFileChooserDialog', { enabled: false });
      await sleep(1500);
    }

    // Walk each <os>/<arch> folder from Agent MCP root and pass real package files into UploadFileBtn
    let queuedCount = 0;
    for (const osDir of osDirPaths) {
      const osName = path.basename(osDir);
      const okRoot = await enter139AgentMcpFolder(cdp);
      if (!okRoot) throw new Error(`139 failed to return to Agent MCP before entering ${osName}`);

      const enteredOs = await click139TableFolder(cdp, osName);
      if (!enteredOs) throw new Error(`139 failed to enter OS folder ${osName}`);

      for (const archName of fs.readdirSync(osDir)) {
        const localDir = path.join(osDir, archName);
        if (!fs.statSync(localDir).isDirectory()) continue;
        const files = fs.readdirSync(localDir).map((f) => path.join(localDir, f)).filter((p) => fs.statSync(p).isFile());

        const enteredArch = await click139TableFolder(cdp, archName);
        if (!enteredArch) throw new Error(`139 failed to enter arch folder ${osName}/${archName}`);

        const existingLeaf = await list139MainTableEntries(cdp);
        const pendingFiles = files.filter((f) => !existingLeaf.files.includes(path.basename(f)));
        console.log(`  [139] ${osName}/${archName}: existing=${existingLeaf.files.length}, pending=${pendingFiles.length}`);
        if (pendingFiles.length > 0) {
          const inp = await cdp.send('Runtime.evaluate', {
            returnByValue: false,
            expression: `document.querySelector('input#UploadFileBtn') || document.querySelector('input#UploadFileBtn01')`,
          });
          if (inp.result && inp.result.objectId) {
            await cdp.send('DOM.setFileInputFiles', { objectId: inp.result.objectId, files: pendingFiles });
            queuedCount += pendingFiles.length;
          }
          await sleep(2400);
        }

        await click139Breadcrumb(cdp, osName);
      }
    }
    await enter139AgentMcpFolder(cdp);
    return `139StructuredUpload(${queuedCount} files across 4 OS dirs)`;
  }

  // 4. UC: Hover upload menu -> <input#ListHeader-list-doc webkitdirectory>
  if (drive.hoverUploadMenu) {
    await cdp.send('Runtime.evaluate', {
      expression: `(() => {
        const btn = document.querySelector('.upload-btn') || Array.from(document.querySelectorAll('button')).find(b => (b.innerText || '').includes('上传'));
        if (btn) {
          btn.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
          btn.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }));
          if (btn.parentElement) btn.parentElement.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
        }
      })()`,
    });
    await sleep(650);
  }

  if (drive.dirSelector) {
    const res = await cdp.send('Runtime.evaluate', {
      returnByValue: false,
      expression: `document.querySelector(${JSON.stringify(drive.dirSelector)})`,
    });
    if (res.result && res.result.objectId) {
      let okCount = 0;
      for (const dirPath of osDirPaths) {
        try {
          if (drive.hoverUploadMenu) {
            await cdp.send('Runtime.evaluate', {
              expression: `(() => {
                const btn = document.querySelector('.upload-btn') || Array.from(document.querySelectorAll('button')).find(b => (b.innerText || '').includes('上传'));
                if (btn) {
                  btn.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
                  btn.dispatchEvent(new MouseEvent('mouseenter', { bubbles: true }));
                  if (btn.parentElement) btn.parentElement.dispatchEvent(new MouseEvent('mouseover', { bubbles: true }));
                }
              })()`,
            });
            await sleep(350);
          }
          const fresh = await cdp.send('Runtime.evaluate', {
            returnByValue: false,
            expression: `document.querySelector(${JSON.stringify(drive.dirSelector)})`,
          });
          const oid = fresh.result && fresh.result.objectId;
          if (!oid) break;
          await cdp.send('DOM.setFileInputFiles', {
            objectId: oid,
            files: [dirPath],
          });
          okCount++;
          await sleep(2200);
        } catch (err) {
          console.log(`  [warn] webkitdirectory setFileInputFiles error on ${path.basename(dirPath)}: ${err.message}`);
          break;
        }
      }
      if (okCount === osDirPaths.length) {
        return `webkitdirectory(${drive.dirSelector}, ${okCount} folders)`;
      }
    }
  }

  return await pasteDirectoriesViaClipboard(cdp, osDirPaths);
}

async function inspectDriveStatus(cdp, drive) {
  await cdp.send('Page.bringToFront');
  await sleep(400);
  await cdp.send('DOM.enable');
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  const expr = `(() => {
    const bodyText = (document.body ? document.body.innerText : '') || '';
    const agentMcpMentions = bodyText.includes('Agent MCP');
    const progressMatches = Array.from(new Set(
      (bodyText.match(/(?:上传中|正在上传|上传完成|秒传|已完成|传输列表\\s*\\d*|共\\s*\\d+\\s*项|\\d+(?:\\.\\d+)?%|\\d+\\/\\d+)/g) || [])
    )).slice(0, 20);
    const isLoggedOut =
      (location.hostname === 'drive.uc.cn' && location.pathname === '/') ||
      bodyText.includes('微信扫码') ||
      bodyText.includes('扫码登录');
    return {
      href: location.href,
      loggedIn: !isLoggedOut,
      inAgentMcp: !isLoggedOut && (agentMcpMentions || decodeURIComponent(location.href).includes('Agent MCP')),
      progressMatches,
    };
  })()`;
  const evalRes = await cdp.send('Runtime.evaluate', { expression: expr, returnByValue: true });
  const info = evalRes.result.value;
  const tree = await fetchRecursiveTree(cdp, drive);
  info.topEntries = tree.topEntries || [];
  info.files = tree.files || [];
  return info;
}

async function openNewDriveTab(targetUrl) {
  const ver = await getJson('/json/version');
  const browserCdp = new CdpClient(ver.webSocketDebuggerUrl);
  try {
    await browserCdp.connect();
    const { targetId } = await browserCdp.send('Target.createTarget', { url: targetUrl });
    await sleep(4500);
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
    cleanOld: false,
    method: 'auto',
    tag: 'v3.5.8',
    drives: null,
    onlyOs: null,
  };
  for (let i = 2; i < argv.length; i++) {
    const a = argv[i];
    if (a === '--status') opts.status = true;
    else if (a === '--refresh') opts.refresh = true;
    else if (a === '--clean-old') opts.cleanOld = true;
    else if (a === '--method' && argv[i + 1]) opts.method = argv[++i];
    else if (a === '--tag' && argv[i + 1]) opts.tag = argv[++i];
    else if (a === '--drives' && argv[i + 1]) opts.drives = argv[++i].split(',').map((s) => s.trim());
    else if (a === '--only-os' && argv[i + 1]) opts.onlyOs = argv[++i].split(',').map((s) => s.trim());
  }
  return opts;
}

async function main() {
  const opts = parseArgs(process.argv);
  const repoRoot = path.resolve(__dirname, '..');
  const stageDir = path.join(repoRoot, 'cloud_drive_upload', opts.tag);
  const structuredRoot = path.join(stageDir, 'structured');

  const targets = await getJson('/json');
  const pages = targets.filter((t) => t.type === 'page' && t.webSocketDebuggerUrl);

  const activeDrives = opts.drives
    ? DRIVES.filter((d) => opts.drives.includes(d.key))
    : DRIVES;

  let osDirPaths = [];
  if (!opts.status) {
    if (!fs.existsSync(structuredRoot)) {
      throw new Error(`Structured directory does not exist: ${structuredRoot}`);
    }
    const targetOsNames = opts.onlyOs || EXPECTED_OS_DIRS;
    osDirPaths = targetOsNames
      .map((d) => path.join(structuredRoot, d))
      .filter((p) => fs.existsSync(p) && fs.statSync(p).isDirectory());
    console.log(`[Stage] ${osDirPaths.length} OS folder(s) ready in ${structuredRoot}: ${osDirPaths.map((p) => path.basename(p)).join(', ')}`);
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
      await cdp.send('Page.bringToFront');
      await sleep(500);
      await cdp.send('Page.enable');
      await cdp.send('Runtime.enable');
      if (drive.key === '139') {
        await cdp.send('Emulation.setDeviceMetricsOverride', {
          width: 1440,
          height: 900,
          deviceScaleFactor: 1,
          mobile: false,
        });
        await sleep(400);
      }

      if (opts.refresh) {
        await cdp.send('Page.reload', { ignoreCache: true });
        await sleep(4500);
        if (drive.key === '139') {
          await enter139AgentMcpFolder(cdp);
        }
      }

      if (drive.key !== '139') {
        const curHref = await cdp.send('Runtime.evaluate', { returnByValue: true, expression: 'location.href' });
        const u = (curHref.result && curHref.result.value) || '';
        if (!decodeURIComponent(u).includes('Agent MCP') && drive.targetUrl) {
          await cdp.send('Page.navigate', { url: drive.targetUrl });
          await sleep(3800);
        }
      } else {
        await enter139AgentMcpFolder(cdp);
      }

      if (opts.cleanOld && !opts.status) {
        const removed = await cleanExistingEntriesInAgentMcp(cdp, drive);
        console.log(`\n[${drive.key}] Cleaned ${removed} previous item(s) inside Agent MCP.`);
      }

      if (opts.status) {
        const info = await inspectDriveStatus(cdp, drive);
        console.log(`\n[${drive.key}] ${drive.name}`);
        console.log(`  URL: ${info.href}`);
        console.log(`  loggedIn: ${info.loggedIn} | inAgentMcp: ${info.inAgentMcp}`);
        console.log(`  Top-level entries (${info.topEntries.length}): ${info.topEntries.map((e) => (e.dir ? e.name + '/' : e.name)).join(', ') || '(none)'}`);
        console.log(`  Recursive files (${info.files.length}):`);
        for (const f of info.files) {
          console.log(`    - ${f}`);
        }
        console.log(`  Progress/Status: ${info.progressMatches.join(' | ') || '(none)'}`);
        continue;
      }

      const methodUsed = await uploadStructuredFolders(cdp, drive, osDirPaths, opts.method);
      console.log(`\n[${drive.key}] ${drive.name}: UPLOAD TRIGGERED via ${methodUsed}`);
    } finally {
      if (drive.key === '139') {
        try {
          await cdp.send('Emulation.clearDeviceMetricsOverride');
        } catch {}
      }
      cdp.close();
    }
  }
}

main().catch((err) => {
  console.error('FATAL:', err.message || err);
  process.exit(1);
});
