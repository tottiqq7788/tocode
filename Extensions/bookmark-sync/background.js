const HOST = "com.tocode.app.bookmark_sync";
const RECONCILE_ALARM = "tocode-bookmark-reconcile";

let port = null;
let applyingBatch = null;
let browserName = detectBrowser();
let profileName = "Default";
let treePushed = false;

function detectBrowser() {
  const ua = (typeof navigator !== "undefined" && navigator.userAgent) || "";
  if (ua.includes("Edg/")) return "edge";
  if (ua.includes("Firefox/")) return "firefox";
  return "chrome";
}

function connect() {
  if (port) {
    try {
      port.disconnect();
    } catch (_) {}
    port = null;
  }
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (error) {
    console.warn("native connect failed", error);
    return;
  }
  port.onMessage.addListener(onHostMessage);
  port.onDisconnect.addListener(() => {
    port = null;
    setTimeout(connect, 3000);
  });
  treePushed = false;
  port.postMessage({
    type: "hello",
    browser: browserName,
    profile: profileName
  });
  pushFullTree();
}

function send(message) {
  if (!port) return;
  try {
    port.postMessage(message);
  } catch (_) {
    port = null;
  }
}

async function pushFullTree() {
  const tree = await chrome.bookmarks.getTree();
  send({ type: "tree", nodes: serializeNodes(tree) });
}

function serializeNodes(nodes) {
  return (nodes || []).map((node) => {
    if (node.url) {
      return {
        type: "bookmark",
        id: String(node.id),
        title: node.title || "",
        url: node.url,
        dateAdded: node.dateAdded || Date.now()
      };
    }
    return {
      type: "folder",
      id: String(node.id),
      title: node.title || "",
      children: serializeNodes(node.children || [])
    };
  });
}

function folderFromPath(pathTitles) {
  const titles = pathTitles || [];
  const root = (titles[0] || "").toLowerCase();
  if (root.includes("toolbar") || root.includes("书签栏") || root.includes("收藏夹栏") || root.includes("bar")) {
    return { kind: "toolbar", segments: titles.slice(1) };
  }
  if (root.includes("mobile") || root.includes("移动")) {
    return { kind: "mobile", segments: titles.slice(1) };
  }
  if (root.includes("other") || root.includes("其他") || titles.length <= 1) {
    return { kind: "other", segments: titles.slice(1) };
  }
  return { kind: "named", segments: titles };
}

async function pathTitlesFor(id) {
  const titles = [];
  let current = id;
  while (current) {
    try {
      const [node] = await chrome.bookmarks.get(current);
      if (!node) break;
      if (node.parentId) {
        titles.unshift(node.title || "");
        current = node.parentId;
      } else {
        break;
      }
    } catch (_) {
      break;
    }
  }
  return titles;
}

chrome.bookmarks.onCreated.addListener(async (_id, bookmark) => {
  if (applyingBatch || !bookmark.url) return;
  const titles = await pathTitlesFor(bookmark.parentId);
  send({
    type: "created",
    url: bookmark.url,
    title: bookmark.title || bookmark.url,
    folder: folderFromPath(titles),
    updatedAt: Date.now() / 1000
  });
});

chrome.bookmarks.onChanged.addListener(async (id, changeInfo) => {
  if (applyingBatch) return;
  try {
    const [node] = await chrome.bookmarks.get(id);
    if (!node || !node.url) return;
    if (changeInfo.url && changeInfo.url !== node.url) {
      // onChanged may include url; treat as change if we tracked old — fall back to update
    }
    const titles = await pathTitlesFor(node.parentId);
    if (changeInfo.url) {
      send({
        type: "changed_url",
        oldUrl: node.url,
        newUrl: changeInfo.url,
        title: changeInfo.title || node.title,
        folder: folderFromPath(titles),
        updatedAt: Date.now() / 1000
      });
      return;
    }
    send({
      type: "updated",
      url: node.url,
      title: changeInfo.title || node.title,
      folder: folderFromPath(titles),
      updatedAt: Date.now() / 1000
    });
  } catch (_) {}
});

chrome.bookmarks.onMoved.addListener(async (id, moveInfo) => {
  if (applyingBatch) return;
  try {
    const [node] = await chrome.bookmarks.get(id);
    if (!node || !node.url) return;
    const titles = await pathTitlesFor(moveInfo.parentId);
    send({
      type: "updated",
      url: node.url,
      title: node.title,
      folder: folderFromPath(titles),
      updatedAt: Date.now() / 1000
    });
  } catch (_) {}
});

chrome.bookmarks.onRemoved.addListener((_id, removeInfo) => {
  if (applyingBatch) return;
  const node = removeInfo && removeInfo.node;
  if (node && node.url) {
    send({ type: "deleted", url: node.url });
    return;
  }
  // 文件夹删除：全量对账补洞
  pushFullTree();
});

async function onHostMessage(message) {
  if (!message || !message.type) return;
  if (message.type === "tree_ok") {
    treePushed = true;
    return;
  }
  if (message.type === "ledger") {
    // 先上报本机树再接受删除，避免后加入浏览器被旧账本清掉独有书签。
    if (!treePushed) return;
    applyingBatch = message.batch || "batch";
    try {
      await applyLedger(message.entries || []);
    } finally {
      applyingBatch = null;
    }
  }
}

async function applyLedger(entries) {
  const tree = await chrome.bookmarks.getTree();
  const existing = flattenBookmarks(tree);
  const byURL = new Map();
  for (const item of existing) {
    byURL.set(canonicalize(item.url), item);
  }
  const wanted = new Map();
  for (const entry of entries) {
    const url = canonicalize(entry.url);
    if (!url) continue;
    wanted.set(url, entry);
  }

  for (const [url, item] of byURL.entries()) {
    if (!wanted.has(url)) {
      try {
        await chrome.bookmarks.remove(item.id);
      } catch (_) {}
    }
  }

  for (const [url, entry] of wanted.entries()) {
    const current = byURL.get(url);
    const parentId = await ensureFolder(entry.folder);
    if (!current) {
      try {
        await chrome.bookmarks.create({
          parentId,
          title: entry.title || url,
          url
        });
      } catch (_) {}
      continue;
    }
    const changes = {};
    if ((entry.title || url) !== (current.title || "")) {
      changes.title = entry.title || url;
    }
    if (Object.keys(changes).length) {
      try {
        await chrome.bookmarks.update(current.id, changes);
      } catch (_) {}
    }
    if (current.parentId !== parentId) {
      try {
        await chrome.bookmarks.move(current.id, { parentId });
      } catch (_) {}
    }
  }
}

function flattenBookmarks(nodes, out = []) {
  for (const node of nodes || []) {
    if (node.url) out.push(node);
    if (node.children) flattenBookmarks(node.children, out);
  }
  return out;
}

function canonicalize(raw) {
  try {
    const u = new URL(raw);
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    u.protocol = u.protocol.toLowerCase();
    u.hostname = u.hostname.toLowerCase();
    if ((u.protocol === "http:" && u.port === "80") || (u.protocol === "https:" && u.port === "443")) {
      u.port = "";
    }
    if (u.pathname.length > 1 && u.pathname.endsWith("/")) {
      u.pathname = u.pathname.slice(0, -1);
    }
    return u.toString();
  } catch (_) {
    return null;
  }
}

async function ensureFolder(folder) {
  const tree = await chrome.bookmarks.getTree();
  const root = tree[0];
  const children = root.children || [];
  let base = children.find((c) => !c.url) || children[0];
  const kind = (folder && folder.kind) || "other";
  if (kind === "toolbar") {
    base = children.find((c) => /toolbar|书签栏|收藏夹栏|bar/i.test(c.title || "")) || children[0];
  } else if (kind === "mobile") {
    base =
      children.find((c) => /mobile|移动/i.test(c.title || "")) ||
      children.find((c) => /other|其他/i.test(c.title || "")) ||
      children[1] ||
      children[0];
  } else {
    base =
      children.find((c) => /other|其他/i.test(c.title || "")) ||
      children[1] ||
      children[0];
  }
  let parentId = base.id;
  const segments = (folder && folder.segments) || [];
  for (const segment of segments) {
    if (!segment) continue;
    const nodes = await chrome.bookmarks.getChildren(parentId);
    let next = nodes.find((n) => !n.url && n.title === segment);
    if (!next) {
      next = await chrome.bookmarks.create({ parentId, title: segment });
    }
    parentId = next.id;
  }
  return parentId;
}

chrome.alarms.create(RECONCILE_ALARM, { periodInMinutes: 5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RECONCILE_ALARM) pushFullTree();
});

connect();
