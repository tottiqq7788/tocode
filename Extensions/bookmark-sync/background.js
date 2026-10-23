const HOST = "com.tocode.app.bookmark_sync";
const RECONCILE_ALARM = "tocode-bookmark-reconcile";

let port = null;
let applyingBatch = null;
let browserName = detectBrowser();
let profileName = "Default";
let treePushed = false;
let pendingLedger = null;
let hostChain = Promise.resolve();
let connecting = false;
let reconnectAttempt = 0;
let reconnectTimer = null;

function detectBrowser() {
  const ua = (typeof navigator !== "undefined" && navigator.userAgent) || "";
  if (ua.includes("Edg/")) return "edge";
  if (ua.includes("Firefox/")) return "firefox";
  return "chrome";
}

function isToolbarTitle(title) {
  const t = (title || "").toLowerCase();
  return (
    t.includes("toolbar") ||
    t.includes("bookmarks bar") ||
    t.includes("favorites bar") ||
    t.includes("书签栏") ||
    t.includes("书签工具栏") ||
    t.includes("收藏夹栏")
  );
}

function isOtherTitle(title) {
  const t = (title || "").toLowerCase();
  return t.includes("other") || t.includes("其他") || t.includes("未整理") || t.includes("unfiled");
}

function isMobileTitle(title) {
  const t = (title || "").toLowerCase();
  return t.includes("mobile") || t.includes("移动");
}

function scheduleReconnect() {
  if (reconnectTimer) return;
  const delay = Math.min(30000, 1000 * Math.pow(2, Math.min(reconnectAttempt, 5)));
  reconnectAttempt += 1;
  reconnectTimer = setTimeout(() => {
    reconnectTimer = null;
    connect();
  }, delay);
}

function connect() {
  if (connecting) return;
  connecting = true;
  if (reconnectTimer) {
    clearTimeout(reconnectTimer);
    reconnectTimer = null;
  }
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
    connecting = false;
    scheduleReconnect();
    return;
  }
  port.onMessage.addListener((message) => {
    hostChain = hostChain.then(() => onHostMessage(message)).catch((error) => {
      console.warn("host message failed", error);
    });
  });
  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError;
    if (err) console.warn("native disconnect", err.message);
    port = null;
    treePushed = false;
    pendingLedger = null;
    connecting = false;
    scheduleReconnect();
  });
  treePushed = false;
  pendingLedger = null;
  try {
    port.postMessage({
      type: "hello",
      browser: browserName,
      profile: profileName
    });
    reconnectAttempt = 0;
    pushFullTree();
  } catch (error) {
    console.warn("native hello failed", error);
    port = null;
    connecting = false;
    scheduleReconnect();
    return;
  }
  connecting = false;
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
    const index = typeof node.index === "number" ? node.index : 0;
    if (node.url) {
      return {
        type: "bookmark",
        id: String(node.id),
        title: node.title || "",
        url: node.url,
        index,
        dateAdded: node.dateAdded || Date.now()
      };
    }
    return {
      type: "folder",
      id: String(node.id),
      title: node.title || "",
      index,
      dateAdded: node.dateAdded || Date.now(),
      children: serializeNodes(node.children || [])
    };
  });
}

function folderFromPath(pathTitles) {
  const titles = pathTitles || [];
  const root = titles[0] || "";
  if (isToolbarTitle(root)) {
    return { kind: "toolbar", segments: titles.slice(1) };
  }
  if (isMobileTitle(root)) {
    return { kind: "mobile", segments: titles.slice(1) };
  }
  if (isOtherTitle(root) || titles.length <= 1) {
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
    index: typeof bookmark.index === "number" ? bookmark.index : 0,
    siblingIndex: typeof bookmark.index === "number" ? bookmark.index : 0,
    updatedAt: Date.now() / 1000
  });
});

chrome.bookmarks.onChanged.addListener(async (id, changeInfo) => {
  if (applyingBatch) return;
  try {
    const [node] = await chrome.bookmarks.get(id);
    if (!node || !node.url) return;
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
    const index = typeof moveInfo.index === "number" ? moveInfo.index : 0;
    send({
      type: "updated",
      url: node.url,
      title: node.title,
      folder: folderFromPath(titles),
      index,
      siblingIndex: index,
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
  pushFullTree();
});

async function onHostMessage(message) {
  if (!message || !message.type) return;
  if (message.type === "tree_ok") {
    treePushed = true;
    // 不再回放积压的整本 ledger：改由主机逐条 upsert 补缺。
    pendingLedger = null;
    // 回告主机：下行通道可用，可以开始补缺。
    send({ type: "tree_ready" });
    return;
  }
  if (message.type === "ledger") {
    // 兼容旧主机：只补缺、不删除，并分批让出事件循环，避免 SW/连接被大包拖死。
    if (!treePushed) {
      pendingLedger = message;
      return;
    }
    applyingBatch = message.batch || "batch";
    try {
      const entries = message.entries || [];
      for (let i = 0; i < entries.length; i += 1) {
        await upsertEntry(entries[i]);
        if (i % 20 === 19) {
          await new Promise((resolve) => setTimeout(resolve, 0));
        }
      }
    } finally {
      applyingBatch = null;
    }
    return;
  }
  if (message.type === "purge_empty_folders") {
    if (!treePushed) {
      send({
        type: "apply_error",
        op: "purge_empty_folders_skipped",
        batch: message.batch || null,
        url: "",
        message: "tree_not_ready"
      });
      return;
    }
    applyingBatch = message.batch || "purge_empty_folders";
    try {
      const removed = await purgeEmptyTitleFoldersUnderRoots();
      send({
        type: "apply_result",
        op: "empty_folders_purged",
        batch: message.batch || null,
        url: "",
        removed
      });
    } catch (error) {
      send({
        type: "apply_error",
        op: "purge_empty_folders",
        batch: message.batch || null,
        url: "",
        message: String(error)
      });
    } finally {
      applyingBatch = null;
    }
    return;
  }
  if (message.type === "ensure_folder") {
    if (!treePushed) {
      send({
        type: "apply_error",
        op: "ensure_folder_skipped",
        batch: message.batch || null,
        url: "",
        message: "tree_not_ready"
      });
      return;
    }
    applyingBatch = message.batch || "ensure_folder";
    try {
      await ensureFolder(message.folder, message.index);
      send({
        type: "apply_result",
        op: "folder_ensured",
        batch: message.batch || null,
        url: "",
        folder: message.folder || null,
        index: typeof message.index === "number" ? message.index : 0
      });
    } catch (error) {
      send({
        type: "apply_error",
        op: "ensure_folder",
        batch: message.batch || null,
        url: "",
        message: String(error)
      });
    } finally {
      applyingBatch = null;
    }
    return;
  }
  if (message.type === "remove_folder") {
    if (!treePushed) {
      send({
        type: "apply_error",
        op: "remove_folder_skipped",
        batch: message.batch || null,
        url: "",
        message: "tree_not_ready"
      });
      return;
    }
    applyingBatch = message.batch || "remove_folder";
    try {
      const result = await removeFolder(message.folder, !!message.recursive);
      send({
        type: "apply_result",
        op: "folder_removed",
        batch: message.batch || null,
        url: "",
        folder: message.folder || null,
        removed: result.removed,
        missing: !!result.missing
      });
    } catch (error) {
      send({
        type: "apply_error",
        op: "remove_folder",
        batch: message.batch || null,
        url: "",
        folder: message.folder || null,
        message: String(error)
      });
    } finally {
      applyingBatch = null;
    }
    return;
  }
  if (message.type === "upsert") {
    if (!treePushed) {
      send({
        type: "apply_error",
        op: "upsert_skipped",
        batch: message.batch || null,
        url: (message.entry && message.entry.url) || "",
        message: "tree_not_ready"
      });
      return;
    }
    applyingBatch = message.batch || "upsert";
    try {
      const result = await upsertEntry(message.entry);
      send({
        type: "apply_result",
        op: result,
        batch: message.batch || null,
        url: (message.entry && message.entry.url) || ""
      });
    } catch (error) {
      send({
        type: "apply_error",
        op: "upsert",
        batch: message.batch || null,
        url: (message.entry && message.entry.url) || "",
        message: String(error)
      });
    } finally {
      applyingBatch = null;
    }
    return;
  }
  if (message.type === "remove") {
    if (!treePushed) {
      send({
        type: "apply_error",
        op: "remove_skipped",
        batch: message.batch || null,
        url: message.url || "",
        message: "tree_not_ready"
      });
      return;
    }
    applyingBatch = message.batch || "remove";
    try {
      await removeByURL(message.url);
      send({
        type: "apply_result",
        op: "removed",
        batch: message.batch || null,
        url: message.url || ""
      });
    } finally {
      applyingBatch = null;
    }
  }
}

async function applyLedgerMessage(message) {
  applyingBatch = message.batch || "batch";
  try {
    await applyLedger(message.entries || []);
  } finally {
    applyingBatch = null;
  }
}

function clampIndex(wanted, childCount, forMoveAlreadyChild) {
  const raw = typeof wanted === "number" && Number.isFinite(wanted) ? Math.floor(wanted) : 0;
  const positive = Math.max(0, raw);
  if (forMoveAlreadyChild) {
    // move 且仍在同一父下：合法下标 0..childCount-1
    const max = Math.max(0, childCount - 1);
    return Math.min(positive, max);
  }
  // create 或跨父 move：合法 0..childCount（append）
  return Math.min(positive, childCount);
}

async function upsertEntry(entry) {
  if (!entry || !entry.url) return "ignored";
  const url = canonicalize(entry.url);
  if (!url) return "ignored";
  const wantedIndex =
    typeof entry.siblingIndex === "number"
      ? entry.siblingIndex
      : typeof entry.index === "number"
        ? entry.index
        : 0;
  // 失败向上抛，由 onHostMessage 统一带 batch 回 apply_error，避免双次回执。
  const parentId = await ensureFolder(entry.folder);
  const tree = await chrome.bookmarks.getTree();
  const existing = flattenBookmarks(tree);
  const matches = existing.filter((item) => canonicalize(item.url) === url);
  const current = matches[0];
  // 同一 URL 多份：保留一份，删掉多余副本。
  for (let i = 1; i < matches.length; i += 1) {
    try {
      await chrome.bookmarks.remove(matches[i].id);
    } catch (_) {}
  }
  const siblings = await chrome.bookmarks.getChildren(parentId);
  if (!current) {
    const index = clampIndex(wantedIndex, siblings.length, false);
    await chrome.bookmarks.create({
      parentId,
      title: entry.title || url,
      url,
      index
    });
    return "created";
  }
  let changed = false;
  const changes = {};
  if ((entry.title || url) !== (current.title || "")) {
    changes.title = entry.title || url;
  }
  if (Object.keys(changes).length) {
    await chrome.bookmarks.update(current.id, changes);
    changed = true;
  }
  const sameParent = current.parentId === parentId;
  const needsMove =
    !sameParent ||
    (typeof current.index === "number" && current.index !== wantedIndex);
  if (needsMove) {
    const index = clampIndex(wantedIndex, siblings.length, sameParent);
    await chrome.bookmarks.move(current.id, { parentId, index });
    changed = true;
  }
  return changed ? "updated" : "exists";
}

async function removeByURL(raw) {
  const url = canonicalize(raw);
  if (!url) return;
  const tree = await chrome.bookmarks.getTree();
  const existing = flattenBookmarks(tree);
  for (const item of existing) {
    if (canonicalize(item.url) !== url) continue;
    try {
      await chrome.bookmarks.remove(item.id);
    } catch (_) {}
  }
}

async function applyLedger(entries) {
  const tree = await chrome.bookmarks.getTree();
  const existing = flattenBookmarks(tree);
  const byURL = new Map();
  for (const item of existing) {
    const key = canonicalize(item.url);
    if (key) byURL.set(key, item);
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
    await upsertEntry({ ...entry, url });
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

function resolveRootBase(children, kind) {
  let base = children[0];
  if (kind === "toolbar") {
    base = children.find((c) => isToolbarTitle(c.title)) || children[0];
  } else if (kind === "mobile") {
    base =
      children.find((c) => isMobileTitle(c.title)) ||
      children.find((c) => isOtherTitle(c.title)) ||
      children[1] ||
      children[0];
  } else if (kind === "named") {
    base = children.find((c) => isOtherTitle(c.title)) || children[1] || children[0];
  } else {
    base = children.find((c) => isOtherTitle(c.title)) || children[1] || children[0];
  }
  return base;
}

async function ensureFolder(folder, siblingIndex) {
  const tree = await chrome.bookmarks.getTree();
  const root = tree[0];
  const children = (root.children || []).filter((c) => !c.url);
  const kind = (folder && folder.kind) || "other";
  const base = resolveRootBase(children, kind);
  if (!base) {
    throw new Error("bookmarks root has no folder children");
  }
  let parentId = base.id;
  const segments = (folder && folder.segments) || [];
  for (let i = 0; i < segments.length; i += 1) {
    const segment = segments[i];
    if (!segment) continue;
    const nodes = await chrome.bookmarks.getChildren(parentId);
    let next = nodes.find((n) => !n.url && n.title === segment);
    const isLeaf = i === segments.length - 1;
    if (!next) {
      const index =
        isLeaf && typeof siblingIndex === "number"
          ? clampIndex(siblingIndex, nodes.length, false)
          : undefined;
      next = await chrome.bookmarks.create(
        index === undefined ? { parentId, title: segment } : { parentId, title: segment, index }
      );
    } else if (isLeaf && typeof siblingIndex === "number" && next.index !== siblingIndex) {
      try {
        const index = clampIndex(siblingIndex, nodes.length, true);
        await chrome.bookmarks.move(next.id, { parentId, index });
      } catch (_) {}
    }
    parentId = next.id;
  }
  return parentId;
}

/// 按账本路径定位夹；不存在返回 null。
async function findFolderNode(folder) {
  const tree = await chrome.bookmarks.getTree();
  const root = tree[0];
  const children = (root.children || []).filter((c) => !c.url);
  const kind = (folder && folder.kind) || "other";
  const base = resolveRootBase(children, kind);
  if (!base) return null;
  let parentId = base.id;
  const segments = (folder && folder.segments) || [];
  if (!segments.length) return null;
  let node = null;
  for (let i = 0; i < segments.length; i += 1) {
    const segment = segments[i];
    if (!segment) continue;
    const nodes = await chrome.bookmarks.getChildren(parentId);
    node = nodes.find((n) => !n.url && n.title === segment) || null;
    if (!node) return null;
    parentId = node.id;
  }
  return node;
}

function nodeHasBookmarkDescendant(node) {
  if (!node) return false;
  if (node.url) return true;
  for (const child of node.children || []) {
    if (nodeHasBookmarkDescendant(child)) return true;
  }
  return false;
}

/// 删除空夹。recursive：删整棵空夹树；夹下有书签则抛错。
async function removeFolder(folder, recursive) {
  const node = await findFolderNode(folder);
  if (!node) {
    return { removed: 0, missing: true };
  }
  // 需要 children 才能判断是否空
  const detailed = (await chrome.bookmarks.getSubTree(node.id))[0];
  if (nodeHasBookmarkDescendant(detailed)) {
    throw new Error("folder_not_empty");
  }
  if (!recursive) {
    const kids = (detailed.children || []).filter((c) => !c.url);
    if (kids.length > 0) {
      throw new Error("folder_has_child_folders");
    }
    await chrome.bookmarks.remove(node.id);
    return { removed: 1, missing: false };
  }
  await chrome.bookmarks.removeTree(node.id);
  return { removed: 1, missing: false };
}

/// 删除 toolbar/other/mobile 下会打乱 siblingIndex 的占位：空标题夹与分隔线（不同步）。
async function purgeEmptyTitleFoldersUnderRoots() {
  const tree = await chrome.bookmarks.getTree();
  const root = tree[0];
  const bases = (root.children || []).filter(
    (c) => !c.url && (isToolbarTitle(c.title) || isOtherTitle(c.title) || isMobileTitle(c.title))
  );
  let removed = 0;
  for (const base of bases) {
    removed += await purgeEmptyTitleFolders(base.id);
  }
  return removed;
}

async function purgeEmptyTitleFolders(parentId) {
  let removed = 0;
  const nodes = await chrome.bookmarks.getChildren(parentId);
  for (const node of nodes) {
    if (node.url) continue;
    // Firefox 分隔线 type=separator，无标题；占位会让绝对下标与账本错位。
    if (node.type === "separator") {
      try {
        await chrome.bookmarks.remove(node.id);
        removed += 1;
      } catch (_) {}
      continue;
    }
    const title = (node.title || "").trim();
    if (!title) {
      try {
        await chrome.bookmarks.removeTree(node.id);
        removed += 1;
      } catch (_) {}
      continue;
    }
    removed += await purgeEmptyTitleFolders(node.id);
  }
  return removed;
}

chrome.alarms.create(RECONCILE_ALARM, { periodInMinutes: 5 });
chrome.alarms.onAlarm.addListener((alarm) => {
  if (alarm.name === RECONCILE_ALARM) pushFullTree();
});

connect();
