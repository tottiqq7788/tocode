const HOST = "com.tocode.app.bookmark_sync";
const RECONCILE_ALARM = "tocode-bookmark-reconcile";
const RECONNECT_ALARM = "tocode-bookmark-reconnect";

let port = null;
let applyingBatch = null;
let browserName = detectBrowser();
let profileName = "Default";
let treePushed = false;
let pendingLedger = null;
let hostChain = Promise.resolve();
let connecting = false;
let reconnectAttempt = 0;
/** disconnect 后递增；过期 apply 回执丢弃。 */
let connectionEpoch = 0;

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

/// 与主机 mapRoot 对齐：精确表 + 窄 contains，禁止裸 includes("other")。
/// Firefox「书签菜单 / Bookmarks Menu」视为 other 别名（与「其他书签」并列）。
function isOtherTitle(title) {
  const raw = title || "";
  const lower = raw.toLowerCase();
  const exact = [
    "其他书签",
    "other bookmarks",
    "其他收藏夹",
    "other favorites",
    "书签菜单",
    "bookmarks menu"
  ];
  if (exact.some((x) => lower === x || raw === x)) return true;
  if (raw.includes("其他书签")) return true;
  if (lower.includes("unfiled") || lower.includes("未整理")) return true;
  return false;
}

/** 新建落点优先「其他书签」类，其次「书签菜单」类，避免 Firefox 双 other 根时全堆到菜单。 */
function isPreferredOtherBookmarksTitle(title) {
  const raw = title || "";
  const lower = raw.toLowerCase();
  return [
    "其他书签",
    "other bookmarks",
    "其他收藏夹",
    "other favorites"
  ].some((x) => lower === x || raw === x) || raw.includes("其他书签");
}

function isBookmarksMenuTitle(title) {
  const raw = title || "";
  const lower = raw.toLowerCase();
  return lower === "书签菜单" || raw === "书签菜单" || lower === "bookmarks menu";
}

function isMobileTitle(title) {
  const raw = title || "";
  const lower = raw.toLowerCase();
  // 「移动设备上的书签」为部分中文界面根标题（勿收成 named）。
  const exact = [
    "移动设备书签",
    "移动设备上的书签",
    "mobile bookmarks",
    "移动收藏夹"
  ];
  if (exact.some((x) => lower === x || raw === x)) return true;
  if (lower.includes("mobile")) return true;
  return false;
}

function scheduleReconnect() {
  reconnectAttempt += 1;
  const delayMinutes = Math.min(0.5, Math.max(0.05, (Math.pow(2, Math.min(reconnectAttempt, 5)) * 1000) / 60000));
  try {
    chrome.alarms.create(RECONNECT_ALARM, { delayInMinutes: delayMinutes });
  } catch (error) {
    console.warn("reconnect alarm failed", error);
  }
}

function connect() {
  if (connecting) return;
  connecting = true;
  try {
    chrome.alarms.clear(RECONNECT_ALARM);
  } catch (_) {}
  if (port) {
    try {
      port.disconnect();
    } catch (_) {}
    port = null;
  }
  // 丢弃上一连接未完成的 hostChain。
  connectionEpoch += 1;
  const epoch = connectionEpoch;
  hostChain = Promise.resolve();
  try {
    port = chrome.runtime.connectNative(HOST);
  } catch (error) {
    console.warn("native connect failed", error);
    connecting = false;
    scheduleReconnect();
    return;
  }
  port.onMessage.addListener((message) => {
    hostChain = hostChain.then(() => {
      if (epoch !== connectionEpoch) return;
      return onHostMessage(message, epoch);
    }).catch((error) => {
      console.warn("host message failed", error);
    });
  });
  port.onDisconnect.addListener(() => {
    const err = chrome.runtime.lastError;
    if (err) console.warn("native disconnect", err.message);
    if (epoch === connectionEpoch) {
      connectionEpoch += 1;
      port = null;
      treePushed = false;
      pendingLedger = null;
      connecting = false;
      scheduleReconnect();
    }
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

function send(message, epoch) {
  if (typeof epoch === "number" && epoch !== connectionEpoch) return;
  if (!port) return;
  try {
    port.postMessage(message);
  } catch (_) {
    port = null;
  }
}

async function pushFullTree() {
  if (!port) {
    connect();
    return;
  }
  const tree = await chrome.bookmarks.getTree();
  send({ type: "tree", nodes: serializeNodes(tree) }, connectionEpoch);
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

async function onHostMessage(message, epoch) {
  if (!message || !message.type) return;
  if (epoch !== connectionEpoch) return;
  const reply = (payload) => send(payload, epoch);
  if (message.type === "tree_ok") {
    treePushed = true;
    // 不再回放积压的整本 ledger：改由主机逐条 upsert 补缺。
    pendingLedger = null;
    // 回告主机：下行通道可用，可以开始补缺。
    reply({ type: "tree_ready" });
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
      reply({
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
      reply({
        type: "apply_result",
        op: "empty_folders_purged",
        batch: message.batch || null,
        url: "",
        removed
      });
    } catch (error) {
      reply({
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
      reply({
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
      const measured = await measureFolderLayout(message.folder);
      reply({
        type: "apply_result",
        op: "folder_ensured",
        batch: message.batch || null,
        url: "",
        folder: message.folder || null,
        index: measured && typeof measured.index === "number"
          ? measured.index
          : typeof message.index === "number"
            ? message.index
            : 0
      });
    } catch (error) {
      reply({
        type: "apply_error",
        op: "ensure_folder",
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
  if (message.type === "remove_folder") {
    if (!treePushed) {
      reply({
        type: "apply_error",
        op: "remove_folder_skipped",
        batch: message.batch || null,
        url: "",
        folder: message.folder || null,
        message: "tree_not_ready"
      });
      return;
    }
    applyingBatch = message.batch || "remove_folder";
    try {
      const result = await removeFolder(message.folder, !!message.recursive);
      reply({
        type: "apply_result",
        op: "folder_removed",
        batch: message.batch || null,
        url: "",
        folder: message.folder || null,
        removed: result.removed,
        missing: !!result.missing,
        evacuatedMoved: (result.evacuated && result.evacuated.moved) || 0,
        evacuatedDeduped: (result.evacuated && result.evacuated.deduped) || 0
      });
    } catch (error) {
      reply({
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
      reply({
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
      reply({
        type: "apply_result",
        op: result.op,
        batch: message.batch || null,
        url: (message.entry && message.entry.url) || "",
        folder: result.folder || (message.entry && message.entry.folder) || null,
        index: typeof result.index === "number" ? result.index : 0,
        title: result.title || (message.entry && message.entry.title) || ""
      });
    } catch (error) {
      reply({
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
      reply({
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
      reply({
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

async function measureBookmarkLayout(bookmarkId, fallbackFolder, fallbackTitle) {
  try {
    const [node] = await chrome.bookmarks.get(bookmarkId);
    if (!node || !node.url) {
      return {
        folder: fallbackFolder || null,
        index: 0,
        title: fallbackTitle || ""
      };
    }
    const titles = await pathTitlesFor(node.parentId);
    return {
      folder: folderFromPath(titles),
      index: typeof node.index === "number" ? node.index : 0,
      title: node.title || fallbackTitle || node.url
    };
  } catch (_) {
    return {
      folder: fallbackFolder || null,
      index: 0,
      title: fallbackTitle || ""
    };
  }
}

async function measureFolderLayout(folder) {
  const node = await findFolderNode(folder);
  if (!node) return null;
  return { index: typeof node.index === "number" ? node.index : 0 };
}

async function upsertEntry(entry) {
  if (!entry || !entry.url) {
    return { op: "ignored", folder: null, index: 0, title: "" };
  }
  const url = canonicalize(entry.url);
  if (!url) {
    return { op: "ignored", folder: entry.folder || null, index: 0, title: entry.title || "" };
  }
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
  let nodeId = current && current.id;
  let op = "exists";
  if (!current) {
    const index = clampIndex(wantedIndex, siblings.length, false);
    const created = await chrome.bookmarks.create({
      parentId,
      title: entry.title || url,
      url,
      index
    });
    nodeId = created.id;
    op = "created";
  } else {
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
    op = changed ? "updated" : "exists";
  }
  const measured = await measureBookmarkLayout(nodeId, entry.folder, entry.title || url);
  return {
    op,
    folder: measured.folder,
    index: measured.index,
    title: measured.title
  };
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

/// 与主机 BookmarkURL.canonicalize 对齐：协议/主机小写、去默认端口与路径尾 `/`；
/// query/fragment 先宽松解码（%2F≡/、大小写 hex 同一身份），再按 URLComponents.string
/// 习惯重新编码：非 ASCII / 空格 / #"<>[]\{}^`|% 等为大写百分号，保留 /?&=+;:@!*'()$ 等。
function decodeURIComponentLenient(s) {
  if (!s) return "";
  try {
    return decodeURIComponent(s.replace(/\+/g, " "));
  } catch (_) {
    return String(s).replace(/%[0-9A-Fa-f]{2}/g, (m) => {
      try {
        return decodeURIComponent(m);
      } catch {
        return m;
      }
    });
  }
}

/** 对齐 Swift URLComponents 对 query/fragment 的 .string 编码。 */
function encodeLikeSwiftURLComponents(decoded) {
  const mustEncodeAscii = new Set([
    0x20, // space
    0x22, // "
    0x23, // #
    0x25, // %
    0x3c, // <
    0x3e, // >
    0x5b, // [
    0x5c, // \
    0x5d, // ]
    0x5e, // ^
    0x60, // `
    0x7b, // {
    0x7c, // |
    0x7d // }
  ]);
  let out = "";
  for (const ch of String(decoded || "")) {
    const code = ch.codePointAt(0);
    if (code < 0x80 && code >= 0x21 && !mustEncodeAscii.has(code)) {
      out += ch;
      continue;
    }
    const bytes = new TextEncoder().encode(ch);
    for (const b of bytes) {
      out += "%" + b.toString(16).toUpperCase().padStart(2, "0");
    }
  }
  return out;
}

function canonicalize(raw) {
  try {
    const u = new URL(raw);
    if (u.protocol !== "http:" && u.protocol !== "https:") return null;
    const protocol = u.protocol.toLowerCase();
    const hostname = u.hostname.toLowerCase();
    if (!hostname) return null;
    let port = u.port;
    if ((protocol === "http:" && port === "80") || (protocol === "https:" && port === "443")) {
      port = "";
    }
    let pathname = u.pathname || "";
    if (pathname.length > 1 && pathname.endsWith("/")) {
      pathname = pathname.slice(0, -1);
    }
    if (pathname === "/") pathname = "";
    const queryDecoded = decodeURIComponentLenient(
      u.search.startsWith("?") ? u.search.slice(1) : u.search
    );
    const fragmentDecoded = decodeURIComponentLenient(
      u.hash.startsWith("#") ? u.hash.slice(1) : u.hash
    );
    const query = queryDecoded ? encodeLikeSwiftURLComponents(queryDecoded) : "";
    const fragment = fragmentDecoded ? encodeLikeSwiftURLComponents(fragmentDecoded) : "";
    let out = protocol + "//";
    if (u.username) {
      out += encodeURIComponent(u.username);
      if (u.password) out += ":" + encodeURIComponent(u.password);
      out += "@";
    }
    out += hostname;
    if (port) out += ":" + port;
    out += pathname;
    if (query) out += "?" + query;
    if (fragment) out += "#" + fragment;
    return out;
  } catch (_) {
    return null;
  }
}

function resolvePreferredOtherRoot(children) {
  const others = (children || []).filter((c) => !c.url && isOtherTitle(c.title));
  if (!others.length) return null;
  return (
    others.find((c) => isPreferredOtherBookmarksTitle(c.title)) ||
    others.find((c) => isBookmarksMenuTitle(c.title)) ||
    others[0]
  );
}

function resolveRootBase(children, kind) {
  let base = children[0];
  if (kind === "toolbar") {
    base = children.find((c) => isToolbarTitle(c.title)) || children[0];
  } else if (kind === "mobile") {
    const mobile = children.find((c) => isMobileTitle(c.title));
    if (mobile) {
      base = mobile;
    } else {
      base = resolvePreferredOtherRoot(children) || children[1] || children[0];
      console.warn("mobile root missing; fallback to", base && base.title);
    }
  } else if (kind === "named") {
    base = resolvePreferredOtherRoot(children) || children[1] || children[0];
  } else {
    // other：新建落点优先「其他书签」，否则「书签菜单」，再任意 other 别名根。
    base = resolvePreferredOtherRoot(children) || children[1] || children[0];
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

/// 在单个根下按 segments 定位夹；中途缺失返回 null。
async function findFolderUnderBase(base, segments) {
  if (!base) return null;
  let parentId = base.id;
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

/// 按账本路径定位夹；不存在返回 null。
/// other：遍历全部 other 别名根（Firefox 可同时有「书签菜单」与「其他书签」），避免假 missing。
async function findFolderNode(folder) {
  const tree = await chrome.bookmarks.getTree();
  const root = tree[0];
  const children = (root.children || []).filter((c) => !c.url);
  const kind = (folder && folder.kind) || "other";
  const segments = (folder && folder.segments) || [];
  if (!segments.length) return null;

  if (kind === "other") {
    const others = children.filter((c) => isOtherTitle(c.title));
    const bases = others.length
      ? others
      : [resolveRootBase(children, kind)].filter(Boolean);
    for (const base of bases) {
      const node = await findFolderUnderBase(base, segments);
      if (node) return node;
    }
    return null;
  }

  const base = resolveRootBase(children, kind);
  return findFolderUnderBase(base, segments);
}

function nodeHasBookmarkDescendant(node) {
  if (!node) return false;
  if (node.url) return true;
  for (const child of node.children || []) {
    if (nodeHasBookmarkDescendant(child)) return true;
  }
  return false;
}

function collectBookmarkNodes(node, out = []) {
  if (!node) return out;
  if (node.url) {
    out.push(node);
    return out;
  }
  for (const child of node.children || []) {
    collectBookmarkNodes(child, out);
  }
  return out;
}

function collectIdsInSubtree(node, out = new Set()) {
  if (!node || !node.id) return out;
  out.add(node.id);
  for (const child of node.children || []) {
    collectIdsInSubtree(child, out);
  }
  return out;
}

/// 删夹前疏散残留书签：树外已有同 URL 则删本副本；同树内同 URL 只留一份迁出，其余 remove。
async function evacuateBookmarksFromSubtree(detailed) {
  const subtreeIds = collectIdsInSubtree(detailed);
  const bookmarks = collectBookmarkNodes(detailed);
  if (!bookmarks.length) return { moved: 0, deduped: 0 };

  const tree = await chrome.bookmarks.getTree();
  const all = flattenBookmarks(tree);
  const root = tree[0];
  const children = (root.children || []).filter((c) => !c.url);
  const otherBase = resolveRootBase(children, "other");
  if (!otherBase) {
    throw new Error("no_other_root_for_evacuate");
  }

  // 同树内同 URL：只保留第一份待迁出，其余直接删。
  const seenInSubtree = new Set();
  const toEvacuate = [];
  let deduped = 0;
  for (const item of bookmarks) {
    const key = canonicalize(item.url) || `raw:${item.id}`;
    if (seenInSubtree.has(key)) {
      try {
        await chrome.bookmarks.remove(item.id);
        deduped += 1;
      } catch (error) {
        throw new Error(`evacuate_dedupe_failed:${String(error)}`);
      }
      continue;
    }
    seenInSubtree.add(key);
    toEvacuate.push(item);
  }

  let moved = 0;
  for (const item of toEvacuate) {
    const key = canonicalize(item.url);
    if (!key) {
      try {
        await chrome.bookmarks.move(item.id, { parentId: otherBase.id });
        moved += 1;
      } catch (moveErr) {
        try {
          await chrome.bookmarks.create({
            parentId: otherBase.id,
            title: item.title || item.url || "bookmark",
            url: item.url
          });
          await chrome.bookmarks.remove(item.id);
          moved += 1;
        } catch (error) {
          throw new Error(`evacuate_move_failed:${String(error || moveErr)}`);
        }
      }
      continue;
    }
    const outside = all.find(
      (b) =>
        b.id !== item.id &&
        !subtreeIds.has(b.id) &&
        canonicalize(b.url) === key
    );
    if (outside) {
      try {
        await chrome.bookmarks.remove(item.id);
        deduped += 1;
      } catch (error) {
        throw new Error(`evacuate_outside_dedupe_failed:${String(error)}`);
      }
      continue;
    }
    try {
      await chrome.bookmarks.move(item.id, { parentId: otherBase.id });
      moved += 1;
    } catch (moveErr) {
      try {
        await chrome.bookmarks.create({
          parentId: otherBase.id,
          title: item.title || key,
          url: item.url
        });
        await chrome.bookmarks.remove(item.id);
        moved += 1;
      } catch (error) {
        throw new Error(`evacuate_move_failed:${String(error || moveErr)}`);
      }
    }
  }
  return { moved, deduped };
}

/// 删除夹。recursive：先疏散残留书签再 removeTree；非 recursive 仅删空叶夹。
async function removeFolder(folder, recursive) {
  const node = await findFolderNode(folder);
  if (!node) {
    return { removed: 0, missing: true };
  }
  let detailed = (await chrome.bookmarks.getSubTree(node.id))[0];
  let evacuated = { moved: 0, deduped: 0 };
  if (nodeHasBookmarkDescendant(detailed)) {
    if (!recursive) {
      throw new Error("folder_not_empty");
    }
    evacuated = await evacuateBookmarksFromSubtree(detailed);
    detailed = (await chrome.bookmarks.getSubTree(node.id))[0];
    if (nodeHasBookmarkDescendant(detailed)) {
      throw new Error("folder_not_empty");
    }
  }
  if (!recursive) {
    const kids = (detailed.children || []).filter((c) => !c.url);
    if (kids.length > 0) {
      throw new Error("folder_has_child_folders");
    }
    await chrome.bookmarks.remove(node.id);
    return { removed: 1, missing: false, evacuated };
  }
  await chrome.bookmarks.removeTree(node.id);
  return { removed: 1, missing: false, evacuated };
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
  if (alarm.name === RECONNECT_ALARM) {
    if (!port) connect();
    return;
  }
  if (alarm.name === RECONCILE_ALARM) {
    if (!port) connect();
    else pushFullTree();
  }
});

connect();
