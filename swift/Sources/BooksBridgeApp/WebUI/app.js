// BooksBridge 前端逻辑。
//
// 两条通路：
//   Swift → Web : window.booksbridge.onState(payload)     状态推送
//                 window.booksbridge.onSettings(payload)  设置推送
//   Web → Swift : window.webkit.messageHandlers.booksbridge.postMessage({type, payload})
//
// 状态分三段：
//   detected —— 实时检测到的书，**只是提示**，点击才进入
//   library  —— 用户主动加入书库的书及其对话（1:N）
//   active   —— 用户当前停留的书与对话

(function () {
  "use strict";

  // ---------- 与宿主通信 ----------

  function invoke(type, payload) {
    const handler = window.webkit?.messageHandlers?.booksbridge;
    if (!handler) {
      console.warn("[booksbridge] 宿主桥未就绪:", type);
      return;
    }
    handler.postMessage({ type, payload: payload ?? {} });
  }

  // ---------- 状态 ----------

  const state = {
    detected: null,
    library: [],
    active: null,
    permissions: { fullDiskAccess: false, accessibility: false },
    permissionLabels: {},
    detectionState: "waiting",
  };

  /** 设置相关状态。 */
  const settingsState = {
    settings: null,
    providers: [],
    knowledgeScopes: [],
    thinkingLevels: [],
    permissionProbe: null,
    /** 用户是否正在编辑（避免被推送覆盖输入中的内容）。 */
    dirty: false,
  };

  /** 问答状态。 */
  const chatState = {
    /** 预处理状态文案与是否就绪（由宿主推送）。 */
    preparation: "",
    preparationReady: false,
    preparationFailed: false,
    /** 当前是否正在流式接收。 */
    streaming: false,
    /** 本轮的知识范围，默认取设置里的默认值。 */
    scope: null,
    /** 正在流式渲染的两块 DOM。 */
    streamNode: null,
    streamReasoning: null,
    streamText: "",
  };

  /** 检测不到书时按原因给出准确提示——不要一律说"未在阅读"。 */
  const DETECTION_MESSAGES = {
    disconnected: ["尚未连接 Apple Books", "在设置 → 权限中点击连接；已有书库和对话仍可查看"],
    dataUnavailable: ["图书数据暂不可用", "在设置 → 权限中查看原因，授权后点重新检测；仍受阻时退出并重新打开应用"],
    noFullDiskAccess: ["缺少完全磁盘访问权限", "在设置 → 权限里授权后即可自动检测"],
    booksNotRunning: ["图书 App 未运行", "打开图书 App 后会自动检测"],
    noBookOpen: ["图书 App 里没有打开的书", "打开一本书后会自动出现"],
    transientError: ["暂时读不到阅读位置", "稍后会自动重试"],
    waiting: ["等待检测…", "正在读取图书 App 状态"],
    ok: ["", ""],
  };

  // ---------- DOM ----------

  const $ = (id) => document.getElementById(id);
  const els = {
    liveDot: $("live-dot"),
    readingCard: $("reading-card"),
    rcTitle: $("rc-title"),
    rcAuthor: $("rc-author"),
    rcKind: $("rc-kind"),
    rcBar: $("rc-bar"),
    rcHint: $("rc-hint"),

    libraryList: $("library-list"),
    libraryEmpty: $("library-empty"),

    settingsBtn: $("settings-btn"),
    settingsBadge: $("settings-badge"),
    hideBtn: $("hide-btn"),

    viewChat: $("view-chat"),
    viewSettings: $("view-settings"),

    crumbBook: $("crumb-book"),
    crumbConv: $("crumb-conv"),
    ctxChip: $("ctx-chip"),
    returnBtn: $("return-btn"),

    teTitle: $("te-title"),
    teBody: $("te-body"),
    threadEmpty: $("thread-empty"),
    messages: $("messages"),
    input: $("input"),
    sendBtn: $("send-btn"),
    cancelBtn: $("cancel-btn"),
    scopePicker: $("scope-picker"),
    usageChip: $("usage-chip"),
    prepBar: $("prep-bar"),
    prepText: $("prep-text"),
    prepRetry: $("prep-retry"),

    settingsNav: $("settings-nav"),
    settingsClose: $("settings-close"),
    permFda: $("perm-fda"),
    permAx: $("perm-ax"),
    permRecheck: $("perm-recheck"),
    probeList: $("probe-list"),
    probeBundle: $("probe-bundle"),
    probeHint: $("probe-hint"),

    setScope: $("set-scope"),
    setMaxTokens: $("set-maxtokens"),
    setProvider: $("set-provider"),
    setApiKey: $("set-apikey"),
    setApiKeyToggle: $("set-apikey-toggle"),
    setBaseURL: $("set-baseurl"),
    setModel: $("set-model"),
    modelSuggestions: $("model-suggestions"),
    setThinking: $("set-thinking"),
    setThinkingHint: $("set-thinking-hint"),
    setTemp: $("set-temp"),
    setTempValue: $("set-temp-value"),
  };

  let activeSection = "general";

  // ---------- 渲染：侧栏 ----------

  function renderSidebar() {
    renderNowReading();
    renderLibrary();
    renderSettingsBadge();
  }

  function renderNowReading() {
    const d = state.detected;

    if (!d) {
      const [title, hint] =
        DETECTION_MESSAGES[state.detectionState] ?? DETECTION_MESSAGES.waiting;
      els.liveDot.className = "dot stale";
      els.rcTitle.textContent = title;
      els.rcAuthor.textContent = "";
      els.rcKind.textContent = "";
      els.rcBar.style.width = "0%";
      els.rcHint.textContent = hint;
      els.readingCard.disabled = true;
      return;
    }

    els.liveDot.className = "dot live";
    els.rcTitle.textContent = d.title || "(无标题)";
    els.rcAuthor.textContent = d.author || "";
    els.rcKind.textContent = d.kind || "";
    els.rcBar.style.width = `${Math.round((d.progress || 0) * 100)}%`;

    const isActive = state.active?.assetID === d.assetID;
    els.rcHint.textContent = isActive
      ? `正在这里 · ${Math.round((d.progress || 0) * 100)}%`
      : d.inLibrary
        ? "已在书库 · 点击进入"
        : "点击加入书库并进入";

    els.readingCard.disabled = false;
  }

  // Both the + menu and slash picker dispatch through this registry.
  const actions = [
    {id:"now", command:"now", label:"刷新当前进度", hint:"本地刷新；/now 问题可刷新后提问"},
    {id:"select", command:"select", label:"读取 Books 划选", hint:"预览并确认本次引用"},
    {id:"scope", command:"scope", label:"查看读取范围", hint:"章节、位置和允许读取的字数"},
    {id:"summary", command:"summary", label:"查看与管理摘要", hint:"查看进度、结果，或手动生成"},
    {id:"new", command:"new", label:"新建对话", hint:"为当前书籍开始新的对话"},
    {id:"generate", label:"生成阅读摘要"},
    {id:"cancelSummary", label:"取消摘要生成"},
    {id:"clearSummary", label:"清除摘要"},
  ];
  let commandMatches = [], commandIndex = 0;
  let menuAnchor = null;
  function feedback(text) { $("command-feedback").textContent = text; $("command-feedback").hidden = false; }
  function actionDisabled(id) {
    if (id === "new") return !state.active?.assetID || chatState.streaming;
    if (!hasConversation()) return true;
    if (id === "summary") return false;
    if (state.active?.archived) return true;
    if (id === "cancelSummary") return !chatState.preparation.startsWith("正在");
    if (chatState.streaming) return true;
    if (id === "generate") return chatState.preparation.startsWith("正在") || !settingsState.settings?.isConfigured;
    if (id === "clearSummary") return !chatState.preparationReady;
    return false;
  }
  function renderActionAvailability() {
    $("actions-btn").disabled = !state.active?.assetID;
    for (const el of document.querySelectorAll("[data-action]")) {
      const id = el.dataset.action; el.disabled = actionDisabled(id);
      if (id === "cancelSummary") el.hidden = !chatState.preparation.startsWith("正在");
      if (id === "clearSummary") el.hidden = !chatState.preparationReady;
      if (id === "generate") el.hidden = chatState.preparation.startsWith("正在");
    }
    $("range-mode").textContent = `读取模式：${settingsState.knowledgeScopes.find(s => s.id === (state.active?.scope || chatState.scope))?.label ?? "尚未选择"}${state.active?.scope ? " · 本对话已固定" : " · 首次提问或生成摘要后固定"}`;
  }
  function closeMenus(restoreFocus = false) {
    $("actions-menu").hidden = true; $("sidebar-menu").hidden = true;
    $("actions-btn").setAttribute("aria-expanded", "false");
    if (restoreFocus) menuAnchor?.focus();
  }
  function showMenu(menu, anchor) {
    menuAnchor = anchor; menu.hidden = false;
    const r = anchor.getBoundingClientRect();
    menu.style.left = `${Math.max(8, Math.min(r.left, innerWidth - menu.offsetWidth - 8))}px`;
    menu.style.top = `${Math.max(8, Math.min(r.top - menu.offsetHeight - 6, innerHeight - menu.offsetHeight - 8))}px`;
  }
  function openPanel(kind) {
    $("reading-panel-title").textContent = kind === "scope" ? "本轮读取范围" : "阅读摘要";
    $("range-panel").hidden = kind !== "scope"; $("summary-panel").hidden = kind === "scope";
    if (!$("reading-panel").open) $("reading-panel").showModal();
  }
  function runAction(id) {
    if (actionDisabled(id)) { feedback("当前状态下无法执行此操作。"); return; }
    closeMenus(); hideCommands(); $("command-feedback").hidden = true;
    switch (id) {
      case "now":
        appendMessage("user", "/now", {roleLabel:"我"}); startStreaming();
        startAssistantMessage(); chatState.streamNode.textContent = "正在刷新阅读位置…";
        invoke("ask", {question:"/now", scope:chatState.scope}); break;
      case "select":
        feedback("正在读取 Books 中的划选…"); invoke("captureSelection"); break;
      case "scope":
        $("reading-check-result").textContent = "正在检查本地正文与当前页…";
        openPanel("scope"); invoke("checkReading", {scope:state.active?.scope || chatState.scope}); break;
      case "summary": openPanel("summary"); break;
      case "generate": {
        const scope = settingsState.knowledgeScopes.find(s => s.id === (state.active?.scope || chatState.scope))?.label ?? "当前范围";
        $("prepare-destination").textContent = `读取范围：${scope}。将该范围内的正文发送至 ${settingsState.settings?.baseURL ?? "当前接口"}，使用 ${settingsState.settings?.model ?? "当前模型"} 生成摘要，会产生 API 用量。确认后刷新本书进度，按刷新后的边界生成。首次生成会固定本对话模式。`;
        if (!$("prepare-confirm").open) $("prepare-confirm").showModal(); break;
      }
      case "cancelSummary": invoke("cancelPreparation"); break;
      case "clearSummary": invoke("clearKnowledge"); break;
      case "new": invoke("newConversation", {assetID:state.active.assetID}); break;
    }
  }
  function hideCommands() {
    $("command-list").hidden = true;
    els.input.removeAttribute("aria-activedescendant"); els.input.setAttribute("aria-expanded", "false");
  }
  function chooseCommand(action) {
    if (!action) return;
    els.input.value = `/${action.command} `; autoGrow(); hideCommands(); renderComposerState(); els.input.focus();
  }
  function renderCommands(reset = true) {
    const match = els.input.value.match(/^\/([a-z]*)$/i);
    if (!match || chatState.streaming) { hideCommands(); return; }
    commandMatches = actions.filter(a => a.command && a.command.startsWith(match[1].toLowerCase()));
    if (!commandMatches.length) { hideCommands(); return; }
    if (reset) commandIndex = 0;
    const list = $("command-list"); list.replaceChildren(); list.hidden = false;
    for (const [index, action] of commandMatches.entries()) {
      const row = button("", "command-option", () => chooseCommand(action));
      row.id = `command-${action.command}`; row.setAttribute("role", "option");
      row.setAttribute("aria-selected", String(index === commandIndex)); row.tabIndex = -1;
      const name = document.createElement("span"); name.textContent = `/${action.command}  ${action.label}`;
      const hint = document.createElement("small"); hint.textContent = action.hint;
      row.append(name, hint); list.append(row);
    }
    els.input.setAttribute("aria-controls", "command-list"); els.input.setAttribute("aria-expanded", "true");
    els.input.setAttribute("aria-activedescendant", `command-${commandMatches[commandIndex].command}`);
    list.children[commandIndex]?.scrollIntoView({block:"nearest"});
  }
  $("actions-btn").addEventListener("click", () => {
    const open = $("actions-menu").hidden; closeMenus(); hideCommands();
    if (open) { renderActionAvailability(); showMenu($("actions-menu"), $("actions-btn")); $("actions-btn").setAttribute("aria-expanded", "true"); $("actions-menu").querySelector("button:not(:disabled):not([hidden])")?.focus(); }
  });
  $("archives-btn").addEventListener("click", () => { renderArchives(); $("archives-panel").showModal(); });
  $("restore-active").addEventListener("click", () => invoke("restoreConversation", {assetID:state.active.assetID, conversationID:state.active.conversationID}));
  document.querySelectorAll("[data-close]").forEach(el => el.addEventListener("click", () => $(el.dataset.close).close()));
  document.addEventListener("click", e => { if (!e.target.closest(".floating-menu, #actions-btn, .row-action")) closeMenus(); });
  window.addEventListener("resize", () => { closeMenus(); hideCommands(); });
  document.addEventListener("keydown", e => {
    const menu = [...document.querySelectorAll(".floating-menu")].find(el => !el.hidden);
    if (!menu) return;
    if (e.key === "Escape") { e.preventDefault(); e.stopImmediatePropagation(); closeMenus(true); }
    if (["ArrowDown", "ArrowUp", "Home", "End"].includes(e.key)) {
      e.preventDefault();
      const options = [...menu.querySelectorAll("button:not(:disabled):not([hidden])")];
      let i = options.indexOf(document.activeElement);
      i = e.key === "Home" ? 0 : e.key === "End" ? options.length - 1 : (i + (e.key === "ArrowUp" ? -1 : 1) + options.length) % options.length;
      options[i]?.focus();
    }
  });
  els.input.addEventListener("input", () => { renderCommands(); $("command-feedback").hidden = true; });

  let librarySignature = "";
  let draggingBook = null;
  function button(text, className, action) {
    const el = document.createElement("button"); el.type = "button";
    el.className = className; el.textContent = text; el.addEventListener("click", action); return el;
  }
  function moveRelative(assetID, delta) {
    const i = state.library.findIndex(b => b.assetID === assetID);
    const target = i + delta;
    if (i < 0 || target < 0 || target >= state.library.length) return;
    invoke("moveBook", {assetID, beforeAssetID: state.library[delta < 0 ? target : target + 1]?.assetID ?? null});
  }
  function sidebarMenu(anchor, items) {
    closeMenus();
    const menu = $("sidebar-menu"); menu.replaceChildren();
    for (const item of items) {
      const el = button(item.label, "", () => { closeMenus(); item.run(); });
      el.disabled = !!item.disabled; el.setAttribute("role", "menuitem"); menu.append(el);
    }
    showMenu(menu, anchor); menu.querySelector("button:not(:disabled)")?.focus();
  }
  function renderLibrary() {
    const signature = JSON.stringify([state.library, state.active?.assetID, state.active?.conversationID]);
    if (signature === librarySignature || draggingBook) return;
    librarySignature = signature;
    const list = els.libraryList; list.replaceChildren();
    els.libraryEmpty.hidden = state.library.length > 0;
    for (const [index, book] of state.library.entries()) {
      const group = document.createElement("div"); group.className = "book-group";
      group.dataset.assetId = book.assetID;
      const bookRow = document.createElement("div"); bookRow.className = "book-row";
      bookRow.draggable = true; bookRow.title = "拖动调整书籍顺序";
      const title = button(book.title, "book-title", () => invoke("openBook", {assetID: book.assetID}));
      title.title = book.title;
      const count = document.createElement("span"); count.className = "bc";
      count.textContent = String(book.conversations.filter(c => !c.archived).length);
      const add = button("＋", "icon-btn row-action", () => invoke("newConversation", {assetID: book.assetID}));
      add.setAttribute("aria-label", `为《${book.title}》新建对话`); add.title = "新建对话";
      const more = button("⋯", "icon-btn row-action", () => sidebarMenu(more, [
        {label:"上移", disabled:index === 0, run:() => moveRelative(book.assetID, -1)},
        {label:"下移", disabled:index === state.library.length - 1, run:() => moveRelative(book.assetID, 1)},
      ]));
      more.setAttribute("aria-label", `移动《${book.title}》`); more.setAttribute("aria-haspopup", "menu");
      bookRow.append(title, count, add, more);
      bookRow.addEventListener("dragstart", e => {
        draggingBook = book.assetID; e.dataTransfer.setData("text/plain", book.assetID); e.dataTransfer.effectAllowed = "move";
        group.classList.add("dragging"); closeMenus();
      });
      bookRow.addEventListener("dragend", () => { draggingBook = null; librarySignature = ""; renderLibrary(); });
      group.addEventListener("dragover", e => {
        if (!draggingBook || draggingBook === book.assetID) return;
        e.preventDefault(); e.dataTransfer.dropEffect = "move";
        const after = e.clientY > group.getBoundingClientRect().top + group.getBoundingClientRect().height / 2;
        group.classList.toggle("drop-before", !after); group.classList.toggle("drop-after", after);
      });
      group.addEventListener("dragleave", e => { if (!group.contains(e.relatedTarget)) group.classList.remove("drop-before", "drop-after"); });
      group.addEventListener("drop", e => {
        e.preventDefault();
        if (!draggingBook || draggingBook === book.assetID) return;
        const after = group.classList.contains("drop-after");
        const assetID = draggingBook; draggingBook = null;
        group.classList.remove("drop-before", "drop-after");
        invoke("moveBook", {assetID, beforeAssetID: after ? state.library[index + 1]?.assetID ?? null : book.assetID});
      });
      const convList = document.createElement("div"); convList.className = "conv-list";
      for (const conversation of book.conversations.filter(c => !c.archived)) {
        const wrap = document.createElement("div"); wrap.className = "conversation-row";
        const row = button(conversation.title, "conv-row", () => invoke("selectConversation", {assetID:book.assetID, conversationID:conversation.id}));
        if (state.active?.assetID === book.assetID && state.active?.conversationID === conversation.id) wrap.classList.add("active");
        const badge = document.createElement("span"); badge.className = "cc";
        badge.textContent = conversation.summaryStatus?.startsWith("正在") ? "◌" : "";
        badge.title = conversation.summaryStatus || "";
        const more = button("⋯", "icon-btn row-action", () => sidebarMenu(more, [
          {label:"归档对话", run:() => invoke("archiveConversation", {assetID:book.assetID, conversationID:conversation.id})},
        ]));
        more.setAttribute("aria-label", `${conversation.title}的操作`); more.setAttribute("aria-haspopup", "menu");
        wrap.append(row, badge, more); convList.append(wrap);
      }
      group.append(bookRow, convList); list.append(group);
    }
    renderArchives();
  }
  function renderArchives() {
    const list = $("archives-list"); list.replaceChildren(); let count = 0;
    for (const book of state.library) {
      const archived = book.conversations.filter(c => c.archived);
      if (!archived.length) continue;
      const title = document.createElement("h4"); title.textContent = book.title; list.append(title);
      for (const c of archived) {
        count++;
        const row = document.createElement("div"); row.className = "archive-row";
        const view = button(c.title, "archive-title", () => { $("archives-panel").close(); invoke("selectConversation", {assetID:book.assetID, conversationID:c.id}); });
        const restore = button("恢复", "btn-plain", () => { $("archives-panel").close(); invoke("restoreConversation", {assetID:book.assetID, conversationID:c.id}); });
        row.append(view, restore); list.append(row);
      }
    }
    $("archives-label").textContent = count ? `已归档 · ${count}` : "已归档";
    if (!count) list.textContent = "没有归档对话。归档后可在这里查看和恢复。";
  }

  /** 设置入口上的小圆点：权限缺失或模型未配置时提示。 */
  function renderSettingsBadge() {
    const needsAttention =
      !state.permissions.fullDiskAccess ||
      !state.permissions.accessibility ||
      (settingsState.settings && !settingsState.settings.isConfigured);
    els.settingsBadge.hidden = !needsAttention;
  }

  // ---------- 渲染：主区（对话） ----------

  function renderChat() {
    const activeBook = state.library.find((b) => b.assetID === state.active?.assetID);

    if (!activeBook) {
      els.crumbBook.textContent = "";
      els.crumbConv.textContent = "";
      els.teTitle.textContent = "选择一本书开始";
      els.teBody.innerHTML =
        "左侧「现在在读」是实时检测结果。<br>点它把书加入书库并进入对话。";
      els.ctxChip.hidden = true;
      renderThreadShell();
    } else {
      els.crumbBook.textContent = activeBook.title;
      const activeConversation = activeBook.conversations.find(
        (c) => c.id === state.active?.conversationID
      );
      els.crumbConv.textContent = activeConversation ? activeConversation.title : "";

      // 有历史时不该再显示空态
      const hasHistory = (activeConversation?.messageCount ?? 0) > 0;
      els.teTitle.textContent = "还没有对话";
      els.teBody.innerHTML =
        "在下面输入问题开始。默认范围是「读到这为止」，不会剧透后面的情节。<br>" +
        "首次提问后范围固定；每次提问会读取本书最新进度。";
      renderThreadShell();
      if (hasHistory) els.threadEmpty.hidden = true;

      // 顶栏右上的上下文提示：仅当检测到的书 == 当前停留的书
      const d = state.detected;
      if (d && activeBook && d.assetID === activeBook.assetID) {
        els.ctxChip.hidden = false;
        els.ctxChip.textContent = `已捕获上下文 · ${Math.round((d.progress || 0) * 100)}%`;
      } else {
        els.ctxChip.hidden = true;
      }
    }

    renderComposerChips();
  }

  /** composer 上方的用量胶囊（旧的两枚状态胶囊已并入范围选择器）。 */
  function renderComposerChips() {
    // 用量在回答完成后由 finishAssistantMessage 填充，这里只负责初始隐藏
    if (!chatState.streaming && els.usageChip.textContent === "") {
      els.usageChip.hidden = true;
    }
  }

  // ---------- 渲染：会话 ----------

  /** 当前会话是否有内容。 */
  function hasConversation() {
    return !!state.active?.conversationID;
  }

  /** 根据是否有会话，切换空态与消息流。 */
  function renderThreadShell() {
    const active = hasConversation();
    els.threadEmpty.hidden = active;
    els.messages.hidden = !active;
  }

  /** 追加一条消息，返回可继续更新的正文节点。 */
  function appendMessage(role, text, options = {}) {
    const wrap = document.createElement("div");
    wrap.className = `msg ${role}`;

    const roleLabel = document.createElement("div");
    roleLabel.className = "msg-role";
    roleLabel.textContent = options.roleLabel ?? (role === "user" ? "我" : settingsState.settings?.model ?? "助手");
    wrap.append(roleLabel);

    if (options.reasoning !== undefined) {
      const details = document.createElement("details");
      details.className = "msg-reasoning";
      details.open = settingsState.settings?.autoExpandReasoning === true;
      const summary = document.createElement("summary");
      summary.textContent = "思考摘要";
      const body = document.createElement("div");
      body.className = "reasoning-body";
      body.textContent = options.reasoning;
      details.append(summary, body);
      wrap.append(details);
    }

    const body = document.createElement("div");
    body.className = "msg-body";
    if (role === "assistant") renderMarkdown(body, text ?? "");
    else body.textContent = text ?? "";
    wrap.append(body);

    if (options.meta) {
      const meta = document.createElement("div");
      meta.className = "msg-meta";
      meta.textContent = options.meta;
      wrap.append(meta);
    }

    els.messages.append(wrap);
    scrollToBottom();
    return body;
  }

  const messageIcons = {
    copy: '<rect x="8" y="8" width="12" height="12" rx="2"/><path d="M16 8V4a2 2 0 0 0-2-2H4a2 2 0 0 0-2 2v10a2 2 0 0 0 2 2h4"/>',
    edit: '<path d="m16 3 5 5M3 21l5-1L21 7a2 2 0 0 0-5-5L3 15v6Z"/>',
    delete: '<path d="M3 6h18M9 6V3h6v3M5 6l1 15h12l1-15M10 10v7M14 10v7"/>',
    retry: '<path d="M3 10a9 9 0 1 1 2 8M3 3v7h7"/>',
  };
  let retryBackup = null;
  function messagePayload(id) {
    return {assetID: state.active.assetID, conversationID: state.active.conversationID, messageID: id};
  }
  function attachMessageActions(wrap, message) {
    wrap.dataset.messageId = message.id || "";
    wrap.dataset.rawText = message.text;
    wrap.dataset.positionCard = String(!!message.isPositionCard);
    wrap.querySelector('.msg-actions')?.remove();
    if (!message.id) return;
    const bar = document.createElement('div'); bar.className = 'msg-actions';
    const actions = message.role === 'user' ? [['copy','复制'], ...(!message.isPositionCard ? [['edit','修改']] : []), ['delete','删除']]
      : [...(message.canRetry ? [['retry','重试']] : []), ['delete','删除']];
    for (const [action, label] of actions) {
      const button = document.createElement('button'); button.className = 'message-action';
      button.dataset.messageAction = action; button.title = label; button.setAttribute('aria-label',label);
      button.innerHTML = `<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.7" stroke-linecap="round" stroke-linejoin="round" aria-hidden="true">${messageIcons[action]}</svg>`;
      button.addEventListener('click', () => {
        if (action !== 'copy' && (chatState.streaming || state.active?.archived)) return;
        if (action === 'edit') { editMessage(wrap, message); return; }
        if (action === 'retry') {
          retryBackup = {wrap, original: wrap.cloneNode(true), message};
          startStreaming(); chatState.streamText = ''; chatState.streamReasoning = null;
          chatState.streamNode = wrap.querySelector('.msg-body');
          wrap.querySelector('.msg-reasoning')?.remove(); wrap.querySelector('.msg-meta')?.remove();
          chatState.streamNode.textContent = '正在思考…';
        }
        invoke(action + 'Message', messagePayload(message.id));
        if (action === 'copy') { button.title = '已复制'; button.setAttribute('aria-label','已复制'); }
      });
      bar.append(button);
    }
    wrap.append(bar); renderMessageActions();
  }
  function renderMessageActions() {
    for (const button of document.querySelectorAll('[data-message-action]')) {
      button.disabled = button.dataset.messageAction !== 'copy' && (chatState.streaming || !!state.active?.archived);
    }
  }
  function editMessage(wrap, message) {
    if (wrap.querySelector('.msg-editor')) return;
    const body = wrap.querySelector('.msg-body'), bar = wrap.querySelector('.msg-actions');
    body.hidden = true; bar.hidden = true;
    const editor = document.createElement('div'); editor.className = 'msg-editor';
    const input = document.createElement('textarea'); input.value = message.text; input.setAttribute('aria-label','修改消息');
    const hint = document.createElement('div'); hint.className = 'msg-editor-hint'; hint.textContent = '保存后可重试原回答；后续旧回答保留显示，不再作为模型上下文。';
    const footer = document.createElement('div'); footer.className = 'msg-editor-footer';
    const cancel = document.createElement('button'); cancel.className = 'btn-plain'; cancel.textContent = '取消';
    const save = document.createElement('button'); save.className = 'btn-plain'; save.textContent = '保存'; save.dataset.saveMessage = message.id;
    const close = () => { editor.remove(); body.hidden = false; bar.hidden = false; };
    cancel.onclick = close;
    save.onclick = () => { if (!input.value.trim() || chatState.streaming) return; if (input.value.trim() === message.text) { close(); return; } invoke('editMessage', {...messagePayload(message.id), text: input.value.trim()}); };
    input.addEventListener('input', () => { save.disabled = !input.value.trim(); });
    input.addEventListener('keydown', e => { e.stopPropagation(); if (e.key === 'Escape' && !e.isComposing) { e.preventDefault(); close(); } });
    footer.append(cancel,save); editor.append(input,hint,footer); wrap.append(editor); input.focus();
  }
  function restoreRetry() {
    if (!retryBackup) return;
    const {wrap,original,message} = retryBackup;
    wrap.replaceWith(original); attachMessageActions(original,message); retryBackup = null;
  }
  function syncMessages() {
    if (chatState.streaming) return;
    const messages = state.active?.messages ?? [];
    const signature = JSON.stringify(messages);
    if (signature === renderedMessagesSignature) return;
    renderedMessagesSignature = signature;
    const existing = [...els.messages.querySelectorAll('.msg')];
    for (const message of messages) {
      let wrap = existing.find(el => message.id && el.dataset.messageId === message.id);
      if (!wrap) wrap = existing.find(el => !el.dataset.messageId && el.classList.contains(message.role) && (el.dataset.rawText ?? el.querySelector('.msg-body')?.textContent) === message.text);
      if (!wrap || (wrap.dataset.rawText !== undefined && wrap.dataset.rawText !== message.text)) {
        wrap = appendMessage(message.role, message.text, {roleLabel: message.isPositionCard ? '阅读位置' : undefined}).closest('.msg');
      }
      const index = existing.indexOf(wrap); if (index >= 0) existing.splice(index,1);
      attachMessageActions(wrap,message); els.messages.append(wrap);
    }
    existing.forEach(el => el.remove());
  }

  function appendError(text) {
    const box = document.createElement("div");
    box.className = "msg-error";
    box.textContent = text;
    els.messages.append(box);
    scrollToBottom();
  }

  function scrollToBottom() {
    els.threadScrollToBottom = true;
    // 用 requestAnimationFrame 等布局完成后再滚
    requestAnimationFrame(() => {
      const thread = document.getElementById("thread");
      if (thread) thread.scrollTop = thread.scrollHeight;
    });
  }

  // ---------- 渲染：预处理状态 ----------

  function renderPreparation() {
    const text = hasConversation() ? (chatState.preparation || "直接读取本地原文 · 未生成摘要") : "";
    if (!text) {
      els.prepBar.hidden = true;
      return;
    }
    els.prepBar.hidden = false;
    els.prepText.textContent = text;
    $("summary-status").textContent = text.replace("本地章节地图 · ", "").replace("未生成范围摘要", "未生成摘要");
    $("summary-status").title = text;
    els.prepBar.classList.toggle("ready", chatState.preparationReady);
    els.prepBar.classList.toggle("failed", chatState.preparationFailed);
    els.prepRetry.hidden = !hasConversation();
    const processing = /正在/.test(text);
    document.getElementById("prep-cancel").hidden = !processing;
    document.getElementById("prep-clear").hidden = !chatState.preparationReady;
    els.prepRetry.hidden = processing || !hasConversation();
    els.prepRetry.disabled = chatState.streaming || !(settingsState.settings?.isConfigured ?? false);
    els.prepRetry.textContent = chatState.preparationReady ? "重新生成摘要" : "生成阅读摘要（可选）";
  }

  // ---------- 渲染：知识范围选择器 ----------

  function renderScopePicker() {
    const scopes = settingsState.knowledgeScopes;
    if (!scopes.length) return;

    // 默认取设置里的默认值
    if (!chatState.scope) {
      chatState.scope = settingsState.settings?.defaultScope ?? scopes[0].id;
    }

    if (els.scopePicker.options.length !== scopes.length) {
      els.scopePicker.replaceChildren(...scopes.map(scope => {
        const option = document.createElement("option");
        option.value = scope.id; option.textContent = scope.label; return option;
      }));
    }
    els.scopePicker.value = chatState.scope;
    els.scopePicker.disabled = !!state.active?.scope || chatState.streaming;
    els.scopePicker.title = state.active?.scope ? "本对话权限已固定；更换权限请新建对话" : "选择本对话的读取权限";
    document.getElementById("composer-model").textContent = settingsState.settings?.model ?? "未配置模型";
    renderPreparation();
  }

  // ---------- 渲染：发送状态 ----------

  function renderComposerState() {
    const configured = settingsState.settings?.isConfigured ?? false;
    const localCommand = /^\/(now|select|scope|summary|new)\s*$/.test(els.input.value.trim());
    const canSend = (configured || localCommand) && hasConversation() && !chatState.streaming
      && !state.active?.archived && els.input.value.trim().length > 0 && (localCommand || !selectedQuote || $("selection-confirmed").checked);

    els.sendBtn.disabled = !canSend;
    els.sendBtn.hidden = chatState.streaming;
    els.cancelBtn.hidden = !chatState.streaming;
    els.input.disabled = !hasConversation() || !!state.active?.archived;
    $("archive-banner").hidden = !state.active?.archived;
    renderActionAvailability();
    renderMessageActions();

    if (!configured) {
      els.input.placeholder = "输入 / 使用阅读命令；提问前请配置 API Key";
    } else if (!hasConversation()) {
      els.input.placeholder = "先在左侧选择一本书";
    } else {
      els.input.placeholder = "就正在读的内容提问，输入 / 使用命令…";
    }
  }

  // ---------- 流式事件 ----------

  function handleChatEvent(event) {
    switch (event.kind) {
      case "status":
        if (!chatState.streamNode) startAssistantMessage();
        if (!chatState.streamText) chatState.streamNode.textContent = event.text;
        break;
      case "reasoning":
        if (!chatState.streamNode) startAssistantMessage();
        if (chatState.streamReasoning) {
          chatState.streamReasoning.textContent += event.text;
        } else {
          // 首次出现思考内容时补一个折叠块
          const details = document.createElement("details");
          details.className = "msg-reasoning";
          details.open = settingsState.settings?.autoExpandReasoning === true;
          const summary = document.createElement("summary");
          summary.textContent = "思考摘要";
          const body = document.createElement("div");
          body.className = "reasoning-body";
          body.textContent = event.text;
          details.append(summary, body);
          chatState.streamNode.parentElement.insertBefore(details, chatState.streamNode);
          chatState.streamReasoning = body;
        }
        scrollToBottom();
        break;

      case "delta":
        if (!chatState.streamNode) startAssistantMessage();
        chatState.streamText += event.text;
        if (!chatState.renderPending) {
          chatState.renderPending = true;
          requestAnimationFrame(() => {
            chatState.renderPending = false;
            if (chatState.streaming && chatState.streamNode) { renderMarkdown(chatState.streamNode, chatState.streamText); showCursor(true); }
          });
        }
        showCursor(true);
        scrollToBottom();
        break;

      case "finished":
        finishAssistantMessage(event);
        break;

      case "error":
        showCursor(false);
        if (retryBackup) { restoreRetry(); chatState.streamNode = null; }
        if (chatState.streamNode && !chatState.streamText) {
          // 还没出内容就失败，把空助手气泡撤掉
          chatState.streamNode.closest(".msg")?.remove();
        }
        appendError(event.text);
        endStreaming();
        break;

      default:
        break;
    }
  }

  function startAssistantMessage() {
    chatState.streamText = "";
    chatState.streamReasoning = null;
    chatState.streamNode = appendMessage("assistant", "正在思考…");
    chatState.streamNode.setAttribute("aria-live", "polite");
    scrollToBottom();
  }

  function showCursor(on) {
    if (!chatState.streamNode) return;
    const existing = chatState.streamNode.querySelector(".cursor");
    if (on && !existing) {
      const cursor = document.createElement("span");
      cursor.className = "cursor";
      chatState.streamNode.append(cursor);
    } else if (!on && existing) {
      existing.remove();
    }
  }

  function finishAssistantMessage(event) {
    showCursor(false);
    if (chatState.streamNode) {
      chatState.streamNode.closest(".msg").dataset.rawText = event.text ?? chatState.streamText;
      if (event.roleLabel) chatState.streamNode.closest(".msg").querySelector(".msg-role").textContent = event.roleLabel;
      renderMarkdown(chatState.streamNode, event.text ?? chatState.streamText);
      // 在气泡下方补一行出处与用量
      const bits = [];
      if (event.scope) bits.push(`范围：${event.scope}`);
      if (event.usage) {
        const u = event.usage;
        const cached = u.cached ? `（缓存命中 ${u.cached}）` : "";
        bits.push(`tokens ${u.prompt}→${u.completion}${cached}`);
      }
      if (bits.length) {
        const meta = document.createElement("div");
        meta.className = "msg-meta";
        meta.textContent = bits.join(" · ");
        chatState.streamNode.closest(".msg")?.append(meta);
      }
      if (event.usage) {
        els.usageChip.hidden = false;
        els.usageChip.textContent = `${event.usage.prompt} → ${event.usage.completion} tok`;
      }
    }
    if (retryBackup) { chatState.streamNode.closest('.msg').dataset.rawText = event.text ?? chatState.streamText; retryBackup = null; }
    endStreaming();
  }

  function endStreaming() {
    chatState.streaming = false;
    chatState.streamNode = null;
    chatState.streamReasoning = null;
    renderComposerState();
    renderScopePicker();
  }

  function startStreaming() {
    lastStopEscape = 0;
    chatState.streaming = true;
    renderComposerState();
    renderScopePicker();
  }

  // ---------- 渲染：设置 ----------

  function renderSettings() {
    const s = settingsState.settings;
    if (!s) return;

    // 服务商下拉
    if (els.setProvider.options.length !== settingsState.providers.length) {
      els.setProvider.textContent = "";
      for (const provider of settingsState.providers) {
        const option = document.createElement("option");
        option.value = provider.id;
        option.textContent = provider.label;
        els.setProvider.append(option);
      }
    }

    // 默认知识范围下拉
    if (els.setScope.options.length !== settingsState.knowledgeScopes.length) {
      els.setScope.textContent = "";
      for (const scope of settingsState.knowledgeScopes) {
        const option = document.createElement("option");
        option.value = scope.id;
        option.textContent = scope.label;
        els.setScope.append(option);
      }
    }

    // 思考模式下拉
    if (els.setThinking.options.length !== settingsState.thinkingLevels.length) {
      els.setThinking.textContent = "";
      for (const level of settingsState.thinkingLevels) {
        const option = document.createElement("option");
        option.value = level.id;
        option.textContent = level.label;
        els.setThinking.append(option);
      }
    }

    // 避免覆盖用户正在输入的内容
    if (!settingsState.dirty) {
      els.setProvider.value = s.provider;
      els.setBaseURL.value = s.baseURL;
      els.setModel.value = s.model;
      els.setScope.value = s.defaultScope;
      els.setThinking.value = s.thinkingLevel;
      document.getElementById("set-auto-expand-reasoning").checked = s.autoExpandReasoning === true;
      els.setMaxTokens.value = String(s.maxContextCharacters);
      els.setTemp.value = String(s.temperature);
      els.setTempValue.textContent = Number(s.temperature).toFixed(1);
      els.setApiKey.value = s.hasAPIKey ? "••••••••••••" : "";
      els.setApiKey.placeholder = s.hasAPIKey ? "已配置（留空则不修改）" : "未配置";
    }

    // 思考模式说明
    els.setThinkingHint.textContent =
      settingsState.thinkingLevels.find((x) => x.id === s.thinkingLevel)?.explanation ?? "";
    // 范围说明
    const scopeInfo = settingsState.knowledgeScopes.find((x) => x.id === s.defaultScope);
    if (scopeInfo) {
      document.getElementById("set-scope-hint").textContent = scopeInfo.explanation;
    }

    // 模型建议
    const provider = settingsState.providers.find((p) => p.id === s.provider);
    els.modelSuggestions.textContent = "";
    for (const model of provider?.models ?? []) {
      const option = document.createElement("option");
      option.value = model;
      els.modelSuggestions.append(option);
    }
    // Ollama 不需要 Key，禁用输入框
    els.setApiKey.disabled = provider ? !provider.requiresAPIKey : false;

    renderPermissionRows();
    renderProbe();
    renderSettingsBadge();
    renderComposerChips();
  }

  /** 渲染"实际读取探测"：这是判断权限是否真的生效的唯一依据。 */
  function renderProbe() {
    const probe = settingsState.permissionProbe;
    if (!probe || !Array.isArray(probe.probes)) {
      els.probeList.textContent = "";
      els.probeHint.textContent = "尚无探测结果，点「重新检测」。";
      els.probeBundle.textContent = "";
      return;
    }

    els.probeHint.textContent = probe.hint ?? "以实际读取结果为准。授权后若仍受阻，请退出并重新打开 BooksBridge，再点击连接。";
    els.probeList.textContent = "";
    for (const item of probe.probes) {
      const li = document.createElement("li");

      const label = document.createElement("span");
      label.className = "pl-label";
      label.textContent = item.label ?? "";

      const result = document.createElement("span");
      result.className = `pl-result ${item.ok ? "ok" : "bad"}`;
      result.textContent = item.result ?? "";

      const path = document.createElement("span");
      path.className = "pl-path";
      path.textContent = item.path ?? "";
      path.title = item.path ?? "";

      li.append(label, result, path);
      els.probeList.append(li);
    }

    els.probeBundle.textContent = probe.signature
      ? `签名：${probe.signature}`
      : "";
  }

  function renderPermissionRows() {
    const rows = [
      [els.permFda, state.permissions.fullDiskAccess],
      [els.permAx, state.permissions.accessibility],
    ];
    for (const [el, ok] of rows) {
      el.textContent = state.permissionLabels[el === els.permFda ? "fullDiskAccess" : "accessibility"] ?? (ok ? "已授权" : "未授权");
      el.className = `perm-state ${ok ? "ok" : "bad"}`;
    }
  }

  function showSection(name) {
    activeSection = name;
    for (const button of els.settingsNav.querySelectorAll(".nav-item")) {
      button.classList.toggle("active", button.dataset.section === name);
    }
    for (const pane of document.querySelectorAll(".pane")) {
      pane.hidden = pane.dataset.pane !== name;
    }
  }

  function showView(which) {
    const toSettings = which === "settings";
    els.viewChat.hidden = toSettings;
    els.viewSettings.hidden = !toSettings;
    document.querySelectorAll(".nav-item").forEach((b) => b.classList.remove("active"));
    if (toSettings) showSection(activeSection);
  }

  /** 当前会话标识，用于判断是否需要整段重绘历史。 */
  let selectedQuote = null;
  let renderedConversationKey = null;
  let renderedMessagesSignature = null;

  /** 切换会话时把历史消息整段重绘。 */
  function syncConversation() {
    const key = state.active
      ? `${state.active.assetID}/${state.active.conversationID ?? ""}`
      : "";
    chatState.scope = state.active?.scope ?? (key !== renderedConversationKey
      ? settingsState.settings?.defaultScope ?? "upToProgress" : chatState.scope);
    renderScopePicker();
    // 会话没变就不动 DOM——流式渲染正在进行时更不能重绘
    if (key === renderedConversationKey) { syncMessages(); return; }
    retryBackup = null; renderedMessagesSignature = null;
    renderedConversationKey = key;
    clearSelection(); closeMenus(); hideCommands();
    for (const id of ["reading-panel", "prepare-confirm"]) if ($(id).open) $(id).close();
    els.input.value = ""; autoGrow();
    $("command-feedback").hidden = true;
    $("summary-status").textContent = "未生成摘要";
    chatState.streaming = false;
    document.getElementById("reading-check-result").textContent = "";
    chatState.preparation = ""; chatState.preparationReady = false; chatState.preparationFailed = false;
    renderComposerState();
    renderScopePicker();

    els.messages.textContent = "";
    chatState.streamNode = null;
    chatState.streamReasoning = null;
    chatState.streamText = "";

    syncMessages();
    renderThreadShell();
  }

  // ---------- 宿主推送 ----------

  // 宿主只有一个推送入口（WebBridge.push → onState），所有消息都从这里进来，
  // 按 payload 里出现了哪些字段来决定更新什么。
  window.booksbridge = {
    onState(payload) {
      // --- 阅读状态 ---
      if (payload.detected !== undefined) state.detected = payload.detected;
      if (Array.isArray(payload.library)) state.library = payload.library;
      if (payload.active !== undefined) state.active = payload.active;
      if (payload.permissionLabels) state.permissionLabels = payload.permissionLabels;
      if (payload.permissions) state.permissions = payload.permissions;
      if (payload.detectionState) state.detectionState = payload.detectionState;

      // --- 设置 ---
      if (payload.settings) {
        settingsState.settings = payload.settings;
        for (const wrap of document.querySelectorAll('.msg.assistant')) {
          if (wrap.dataset.positionCard !== 'true') wrap.querySelector('.msg-role').textContent = payload.settings.model ?? '助手';
        }
      }
      if (Array.isArray(payload.providers)) settingsState.providers = payload.providers;
      if (Array.isArray(payload.knowledgeScopes)) settingsState.knowledgeScopes = payload.knowledgeScopes;
      if (Array.isArray(payload.thinkingLevels)) settingsState.thinkingLevels = payload.thinkingLevels;
      if (payload.permissionProbe) settingsState.permissionProbe = payload.permissionProbe;

      if (payload.apiTest && payload.apiTest.requestID === apiRequestID) {
        apiResult.textContent = payload.apiTest.text; apiTestButton.disabled = false;
      }
      if (payload.openSettings) showView("settings");

      // 会话历史：仅在切换会话时整段重绘，避免与流式渲染互相打架
      if (payload.active !== undefined) syncConversation();

      // 问答事件（流式增量等）
      if (payload.chatEvent) handleChatEvent(payload.chatEvent);
      if (payload.messageActionError) appendError(payload.messageActionError);

      if (payload.readingPosition !== undefined) {
        $("reading-position").textContent = (chatState.streaming ? "本轮读取 · " : "") + payload.readingPosition;
        $("reading-position").title = $("reading-position").textContent;
        $("range-position").textContent = payload.readingPosition;
      }
      if (payload.positionCard) {
        const card = appendMessage("assistant", payload.positionCard, {roleLabel:"阅读位置"});
        if (chatState.streamNode) els.messages.insertBefore(card.closest(".msg"), chatState.streamNode.closest(".msg"));
      }
      if (payload.summaryMetadata !== undefined) $("summary-metadata").textContent = payload.summaryMetadata;
      if (payload.scopeSummary !== undefined) {
        document.getElementById("scope-summary").hidden = !payload.scopeSummary;
        renderMarkdown(document.getElementById("scope-summary-text"), payload.scopeSummary);
      }
      if (payload.selectionCandidate) {
        $("command-feedback").hidden = true;
        clearSelection();
        const value = payload.selectionCandidate;
        if (value.error) appendError(value.error);
        else {
          selectedQuote = value;
          document.getElementById("selection-preview").hidden = false;
          $("selection-details").open = true;
          $("selection-excerpt").textContent = value.text.slice(0, 70) + (value.text.length > 70 ? "…" : "");
          document.getElementById("selection-text").textContent = value.text;
          document.getElementById("selection-kind").textContent = value.exact ? "精确划选 · 请确认" : "整段候选 · Books 未提供精确划词，请核对";
        }
      }
      if (payload.readingCheck) document.getElementById("reading-check-result").textContent = payload.readingCheck;
      if (payload.preparationJobs) {
        document.getElementById("preparation-jobs").textContent = payload.preparationJobs.filter(job => job.status.startsWith("正在")).map(job => `${job.title}：${job.status}`).join("\n");
      }
      // 预处理状态
      if (payload.assistant) {
        chatState.preparation = payload.assistant.preparation ?? "";
        chatState.preparationReady = payload.assistant.ready === true;
        chatState.preparationFailed = /失败/.test(chatState.preparation);
      }

      renderSidebar();
      renderChat();
      renderSettings();
      renderScopePicker();
      renderPreparation();
      renderComposerState();
      reportRenderStats();
    },
  };

  // ---------- 渲染回报（用于自动化验证） ----------

  function reportRenderStats() {
    invoke("renderStats", {
      view: els.viewSettings.hidden ? "chat" : "settings",
      sidebarWidth: document.getElementById("sidebar").getBoundingClientRect().width,
      domBooks: document.querySelectorAll(".book-row").length,
      domConvs: document.querySelectorAll(".conv-row").length,
      domActiveConv: document.querySelectorAll(".conv-row.active").length,
      domNavItems: document.querySelectorAll(".nav-item").length,
      activePane: [...document.querySelectorAll(".pane")].find((p) => !p.hidden)?.dataset.pane ?? "",
      providerOptions: els.setProvider.options.length,
      scopeOptions: els.setScope.options.length,
      modelValue: els.setModel.value,
      baseURLValue: els.setBaseURL.value,
      scopeValue: els.setScope.value,
      hasAPIKey: settingsState.settings?.hasAPIKey ?? false,
      isConfigured: settingsState.settings?.isConfigured ?? false,
      settingsBadgeHidden: els.settingsBadge.hidden,
      permFda: els.permFda.textContent,
      permAx: els.permAx.textContent,
      probeRows: document.querySelectorAll(".probe-list li").length,
      probeAllOk: (settingsState.permissionProbe?.probes ?? []).every((x) => x.ok),
      crumbBook: els.crumbBook.textContent,
      crumbConv: els.crumbConv.textContent,
      emptyTitle: els.teTitle.textContent,
      inputDisabled: els.input.disabled,
      scopeOptions: els.scopePicker.querySelectorAll(".scope-option").length,
      activeScope: chatState.scope ?? "",
      streaming: chatState.streaming,
      messageCount: els.messages.querySelectorAll(".msg").length,
      prepVisible: !els.prepBar.hidden,
      prepText: els.prepText.textContent,
      // 布局自检：所有区块都应在视口内且互不重叠
      overlaps: detectOverlaps(),
      // 各区块尺寸：用于确认布局没有被压扁（无重叠 ≠ 有可用空间）
      sizes: measureBlocks(),
    });
  }

  /** 主要区块的尺寸，形如 "sidebar=270x660 topbar=789x52 thread=789x537 composer=789x63"。 */
  function measureBlocks() {
    const selectors = [
      ["sidebar", "#sidebar"],
      ["topbar", ".topbar"],
      ["thread", "#thread"],
      ["composer", ".composer"],
      ["nav", "#settings-nav"],
      ["pane", "#settings-pane"],
    ];
    return selectors
      .map(([name, selector]) => {
        const el = document.querySelector(selector);
        if (!el) return `${name}=缺失`;
        const r = el.getBoundingClientRect();
        // 尺寸为 0 或不可见都算"未渲染"
        if (r.width === 0 || r.height === 0 || el.hidden) return `${name}=未显示`;
        return `${name}=${Math.round(r.width)}x${Math.round(r.height)}`;
      })
      .join(" ");
  }

  /**
   * 布局自检：检查主要区块是否互相重叠。
   *
   * 这是对"不重叠、正确排布"要求的自动化验证——
   * 手写 flex 布局最容易出的问题就是某个子项撑破容器后压到相邻区块上。
   */
  function detectOverlaps() {
    const selectors = [
      ["sidebar", "#sidebar"],
      ["topbar", ".topbar"],
      ["thread", "#thread"],
      ["composer", ".composer"],
    ];
    const boxes = selectors
      .map(([id, selector]) => {
        const el = document.querySelector(selector);
        if (!el || el.hidden) return null;
        const r = el.getBoundingClientRect();
        if (r.width === 0 || r.height === 0) return null;
        return { id, top: r.top, left: r.left, right: r.right, bottom: r.bottom, w: r.width, h: r.height };
      })
      .filter(Boolean);

    const problems = [];
    for (let i = 0; i < boxes.length; i++) {
      for (let j = i + 1; j < boxes.length; j++) {
        const a = boxes[i], b = boxes[j];
        // 只关心"有实际面积的重叠"，1pt 内的接缝不算
        const ox = Math.min(a.right, b.right) - Math.max(a.left, b.left);
        const oy = Math.min(a.bottom, b.bottom) - Math.max(a.top, b.top);
        if (ox > 1 && oy > 1) {
          problems.push(`${a.id}×${b.id}(${Math.round(ox)}×${Math.round(oy)})`);
        }
      }
      // 可见区块的高度必须为正，否则说明布局塌陷
      // （尺寸为 0 的元素已在上面被过滤掉，这里只防负数）
      if (boxes[i].h < 0 || boxes[i].w < 0) {
        problems.push(`${boxes[i].id}(尺寸异常)`);
      }
    }
    return problems.join(", ") || "无";
  }

  // ---------- 交互：侧栏 ----------

  els.readingCard.addEventListener("click", () => {
    if (!state.detected) return;
    invoke("openBook", { assetID: state.detected.assetID });
  });

  els.settingsBtn.addEventListener("click", () => {
    showView("settings");
    // 让宿主把最新设置推过来
    invoke("openSettings");
  });

  els.hideBtn.addEventListener("click", () => invoke("hidePage"));

  // ---------- 交互：对话 ----------

  els.returnBtn.addEventListener("click", () => invoke("returnToReader"));

  function clearSelection() {
    selectedQuote = null;
    $("selection-preview").classList.remove("confirmed");
    document.getElementById("selection-preview").hidden = true;
    document.getElementById("selection-confirmed").checked = false;
  }
  document.getElementById("selection-clear").addEventListener("click", () => { clearSelection(); renderComposerState(); });
  document.getElementById("selection-confirmed").addEventListener("change", () => {
    $("selection-details").open = !$("selection-confirmed").checked;
    $("selection-preview").classList.toggle("confirmed", $("selection-confirmed").checked);
    renderComposerState();
  });

  function send() {
    const question = els.input.value.trim();
    if (!question || chatState.streaming || !hasConversation() || state.active?.archived) return;
    const command = question.match(/^\/([^\s]+)(?:\s+([\s\S]*))?$/);
    if (command && !(command[1] === "now" && command[2]?.trim())) {
      const action = actions.find(a => a.command === command[1]);
      if (!action || command[2]?.trim()) { feedback("未识别的命令。输入 / 查看可用命令；仅 /now 支持附带问题。"); return; }
      if (actionDisabled(action.id)) { feedback("当前状态下无法执行此操作。"); return; }
      els.input.value = ""; autoGrow(); hideCommands(); renderComposerState(); runAction(action.id); return;
    }
    if (!(settingsState.settings?.isConfigured ?? false)) { feedback("请先在设置中配置模型接口。"); return; }
    if (selectedQuote && !document.getElementById("selection-confirmed").checked) return;
    appendMessage("user", question + (selectedQuote ? "\n\n引用：\n" + selectedQuote.text : ""), { roleLabel: "我" });
    els.input.value = "";
    autoGrow(); hideCommands(); $("command-feedback").hidden = true;
    startStreaming();
    startAssistantMessage();

    invoke("ask", { question, scope: chatState.scope,
      ...(selectedQuote ? {selectionToken:selectedQuote.token, selectionConfirmed:true} : {}) });
    clearSelection();
  }

  els.sendBtn.addEventListener("click", send);
  function stopGeneration() {
    if (!chatState.streaming) return;
    invoke("cancelAnswer"); showCursor(false);
    if (retryBackup) restoreRetry();
    else if (chatState.streamNode && !chatState.streamText) chatState.streamNode.textContent = "已停止";
    endStreaming();
  }
  els.cancelBtn.addEventListener('click', stopGeneration);
  for (const button of [els.sendBtn, els.cancelBtn]) button.addEventListener('mousedown', e => e.preventDefault());
  els.scopePicker.addEventListener("change", () => {
    if (!state.active?.scope) chatState.scope = els.scopePicker.value;
    renderScopePicker();
  });
  document.querySelectorAll("[data-action]").forEach(el => el.addEventListener("click", () => runAction(el.dataset.action)));
  $("prepare-yes").addEventListener("click", () => {
    $("prepare-confirm").close(); invoke("reprocessBook", {confirmed:true, scope:state.active?.scope || chatState.scope}); openPanel("summary");
  });
  $("prepare-no").addEventListener("click", () => $("prepare-confirm").close());
  let apiRequestID = "";
  const apiResult = document.getElementById("api-test-result");
  const apiTestButton = document.getElementById("api-test");
  for (const field of [els.setBaseURL, els.setModel, els.setApiKey, els.setProvider].filter(Boolean)) {
    field.addEventListener("input", () => {
      apiRequestID = ""; apiTestButton.disabled = false; apiResult.textContent = "配置已改变，请重新检测";
    });
  }
  apiTestButton.addEventListener("click", () => {
    apiRequestID = String(Date.now()); apiTestButton.disabled = true; apiResult.textContent = "正在检测…";
    const key = els.setApiKey.value.trim();
    invoke("testAPI", { requestID: apiRequestID, baseURL: els.setBaseURL.value.trim(), model: els.setModel.value.trim(),
      ...((key && !/^•+$/.test(key)) ? { apiKey: key } : {}) });
  });

  els.input.addEventListener("input", () => {
    autoGrow();
    renderComposerState();
  });

  els.input.addEventListener("keydown", (event) => {
    if (event.isComposing) return;
    if (!$("command-list").hidden && ["ArrowDown", "ArrowUp", "Enter", "Tab", "Escape"].includes(event.key) && !event.shiftKey) {
      event.preventDefault(); event.stopPropagation();
      if (event.key === "Escape") { hideCommands(); return; }
      if (event.key === "ArrowDown" || event.key === "ArrowUp") {
        commandIndex = (commandIndex + (event.key === "ArrowDown" ? 1 : -1) + commandMatches.length) % commandMatches.length;
        renderCommands(false); return;
      }
      chooseCommand(commandMatches[commandIndex]); return;
    }
    if (event.key === "Enter" && !event.shiftKey) { event.preventDefault(); send(); }
  });

  /** 输入框随内容长高，到上限后内部滚动。 */
  function autoGrow() {
    els.input.style.height = "auto";
    els.input.style.height = `${Math.min(els.input.scrollHeight, 160)}px`;
  }

  // ---------- 交互：设置 ----------

  els.settingsClose.addEventListener("click", () => {
    collectAndSave();
    showView("chat");
  });

  els.settingsNav.addEventListener("click", (event) => {
    const button = event.target.closest(".nav-item");
    if (button) showSection(button.dataset.section);
  });

  for (const el of document.querySelectorAll("[data-open-settings]")) {
    el.addEventListener("click", () => {
      invoke("openSystemSettings", { which: el.dataset.openSettings });
    });
  }

  els.permRecheck.addEventListener("click", () => {
    // 让宿主重新探测一次（会重新尝试真实读取）
    invoke("recheckPermissions");
  });
  $("perm-connect").addEventListener("click", () => invoke("connectBooks"));

  els.setApiKeyToggle.addEventListener("click", () => {
    const showing = els.setApiKey.type === "text";
    els.setApiKey.type = showing ? "password" : "text";
    els.setApiKeyToggle.textContent = showing ? "显示" : "隐藏";
  });

  els.setTemp.addEventListener("input", () => {
    els.setTempValue.textContent = Number(els.setTemp.value).toFixed(1);
    settingsState.dirty = true;
  });

  // 任何设置控件的改动都标记为 dirty，防止推送覆盖
  for (const el of [
    els.setProvider, els.setBaseURL, els.setModel,
    els.setScope, els.setMaxTokens, els.setApiKey, els.setThinking, document.getElementById("set-auto-expand-reasoning"),
  ]) {
    el.addEventListener("input", () => { settingsState.dirty = true; });
    el.addEventListener("change", () => { settingsState.dirty = true; });
  }

  // 换服务商时把地址与模型换成该服务商的默认值，减少手填
  els.setProvider.addEventListener("change", () => {
    const provider = settingsState.providers.find((p) => p.id === els.setProvider.value);
    if (!provider) return;
    if (provider.defaultBaseURL) els.setBaseURL.value = provider.defaultBaseURL;
    if (provider.models?.length) els.setModel.value = provider.models[0];
    els.setApiKey.disabled = !provider.requiresAPIKey;
    renderSettings();
  });

  /** 收集设置并提交给宿主。 */
  function collectAndSave() {
    if (!settingsState.dirty) return;
    const payload = {
      provider: els.setProvider.value,
      baseURL: els.setBaseURL.value.trim(),
      model: els.setModel.value.trim(),
      defaultScope: els.setScope.value,
      thinkingLevel: els.setThinking.value,
      autoExpandReasoning: document.getElementById("set-auto-expand-reasoning").checked,
      maxContextCharacters: Number(els.setMaxTokens.value) || 12000,
      temperature: Number(els.setTemp.value) || 0,
    };
    // 密码框里是掩码占位符时不要提交
    const key = els.setApiKey.value.trim();
    if (key && !/^•+$/.test(key)) payload.apiKey = key;

    invoke("saveSettings", payload);
    settingsState.dirty = false;
  }

  // ---------- 键盘 ----------

  let lastStopEscape = 0;
  window.addEventListener('blur', () => { lastStopEscape = 0; });
  window.addEventListener("keydown", (event) => {
    if (chatState.streaming) {
      if (event.key !== 'Escape' || event.defaultPrevented || event.repeat || event.isComposing || event.metaKey || event.ctrlKey || event.altKey || event.shiftKey || document.querySelector('dialog[open]') || !els.viewSettings.hidden) { lastStopEscape = 0; return; }
      event.preventDefault();
      const now = performance.now();
      if (lastStopEscape && now - lastStopEscape <= 500) { lastStopEscape = 0; stopGeneration(); }
      else lastStopEscape = now;
      return;
    }
    const isSettings = !els.viewSettings.hidden;

    if (event.key === "Escape" && document.querySelector("dialog[open]")) return;
    if (event.key === "Escape") {
      event.preventDefault();
      if (isSettings) {
        collectAndSave();
        showView("chat");
      } else {
        invoke("returnToReader");
      }
      return;
    }
    if (event.metaKey && event.key.toLowerCase() === "w") {
      event.preventDefault();
      invoke("hidePage");
      return;
    }
    if (event.metaKey && event.key === ",") {
      event.preventDefault();
      showView("settings");
      invoke("openSettings");
    }
  });

  // 离开页面前保存（关窗口时宿主会直接隐藏，这里尽力而为）
  window.addEventListener("beforeunload", collectAndSave);

  invoke("ready");
})();
