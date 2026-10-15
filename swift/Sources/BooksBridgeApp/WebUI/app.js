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
    if (["openBook", "selectConversation", "newConversation", "restoreConversation"].includes(type)) {
      if (payload?.assetID && collapsedBooks.has(payload.assetID)) setBookCollapsed(payload.assetID, false);
      closeSummary(); showView("chat");
    }
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
    ambiguousBook: ["需要确认当前书籍", "无法可靠区分当前窗口的来源文件，请确认书籍后继续"],
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
  let sidebarCollapsed = false;
  let collapsedBooks = new Set();
  const sidebarDefaultWidth = 248, sidebarMinWidth = 210, sidebarMaxWidth = 480, chatMinWidth = 440;
  let sidebarPreferredWidth = sidebarDefaultWidth;
  let sidebarResize = null;
  const sidebarResizer = $("sidebar-resizer");

  function sidebarWidthLimit() { return Math.max(sidebarMinWidth, Math.min(sidebarMaxWidth, Math.floor(innerWidth - chatMinWidth))); }
  function applySidebarWidth() {
    const width = Math.round(Math.max(sidebarMinWidth, Math.min(sidebarWidthLimit(), sidebarPreferredWidth)));
    document.documentElement.style.setProperty("--side-w", `${width}px`);
    sidebarResizer.setAttribute("aria-valuemax", String(sidebarWidthLimit()));
    sidebarResizer.setAttribute("aria-valuenow", String(width));
    sidebarResizer.setAttribute("aria-valuetext", `${width} 像素`);
  }

  function renderSidebarLayout() {
    const toggle = $("sidebar-toggle");
    const hadSidebarFocus = $("sidebar").contains(document.activeElement);
    $("app").classList.toggle("sidebar-collapsed", sidebarCollapsed);
    $("sidebar").inert = sidebarCollapsed;
    applySidebarWidth();
    const label = sidebarCollapsed ? "展开侧栏" : "收起侧栏";
    toggle.setAttribute("aria-expanded", String(!sidebarCollapsed));
    toggle.setAttribute("aria-label", label); toggle.title = label;
    if (sidebarCollapsed && hadSidebarFocus) toggle.focus({preventScroll:true});
    syncTitlebarHitRegions();
  }

  function saveSidebarWidth(width) {
    sidebarPreferredWidth = Math.round(Math.max(sidebarMinWidth, Math.min(sidebarWidthLimit(), width)));
    applySidebarWidth(); syncTitlebarHitRegions();
    invoke("setSidebarWidth", {width:sidebarPreferredWidth});
  }

  function finishSidebarResize(cancelled = false) {
    if (!sidebarResize) return;
    const {pointerId, originalWidth, moved} = sidebarResize;
    sidebarResize = null;
    $("app").classList.remove("sidebar-resizing");
    if (sidebarResizer.hasPointerCapture(pointerId)) sidebarResizer.releasePointerCapture(pointerId);
    if (cancelled) sidebarPreferredWidth = originalWidth;
    applySidebarWidth(); syncTitlebarHitRegions();
    if (!cancelled && moved) invoke("setSidebarWidth", {width:sidebarPreferredWidth});
  }

  sidebarResizer.addEventListener("pointerdown", event => {
    if (event.button !== 0 || sidebarCollapsed || document.querySelector('dialog[open]')) return;
    event.preventDefault(); closeMenus(); hideCommands();
    sidebarResize = {pointerId:event.pointerId, startX:event.clientX, startWidth:$("sidebar").getBoundingClientRect().width, originalWidth:sidebarPreferredWidth, moved:false};
    $("app").classList.add("sidebar-resizing");
    sidebarResizer.focus({preventScroll:true});
    // Window listeners also cover engines or interrupted gestures without pointer capture.
    try { sidebarResizer.setPointerCapture(event.pointerId); } catch (_) {}
  });
  window.addEventListener("pointermove", event => {
    if (!sidebarResize || event.pointerId !== sidebarResize.pointerId) return;
    const delta = event.clientX - sidebarResize.startX;
    if (!sidebarResize.moved && Math.abs(delta) < 1) return;
    sidebarResize.moved = true;
    sidebarPreferredWidth = Math.round(Math.max(sidebarMinWidth, Math.min(sidebarWidthLimit(), sidebarResize.startWidth + delta)));
    applySidebarWidth(); syncTitlebarHitRegions();
  });
  window.addEventListener("pointerup", event => { if (event.pointerId === sidebarResize?.pointerId) finishSidebarResize(); });
  window.addEventListener("pointercancel", event => { if (event.pointerId === sidebarResize?.pointerId) finishSidebarResize(true); });
  sidebarResizer.addEventListener("lostpointercapture", () => finishSidebarResize(true));
  window.addEventListener("blur", () => finishSidebarResize(true));
  window.addEventListener("resize", () => { finishSidebarResize(true); applySidebarWidth(); syncTitlebarHitRegions(); });
  window.addEventListener("keydown", event => {
    if (sidebarResize && event.key === "Escape") { event.preventDefault(); event.stopImmediatePropagation(); finishSidebarResize(true); }
  }, true);
  sidebarResizer.addEventListener("dblclick", () => saveSidebarWidth(sidebarDefaultWidth));
  sidebarResizer.addEventListener("keydown", event => {
    if (!["ArrowLeft", "ArrowRight", "Home", "End"].includes(event.key)) return;
    event.preventDefault();
    const width = Number(sidebarResizer.getAttribute("aria-valuenow"));
    saveSidebarWidth(event.key === "Home" ? sidebarMinWidth : event.key === "End" ? sidebarWidthLimit() : width + (event.key === "ArrowLeft" ? -10 : 10));
  });

  $("sidebar-toggle").addEventListener("click", () => {
    finishSidebarResize(true);
    sidebarCollapsed = !sidebarCollapsed;
    closeMenus(); hideCommands(); renderSidebarLayout();
    invoke("setSidebarCollapsed", {collapsed:sidebarCollapsed});
  });

  function setBookCollapsed(assetID, collapsed) {
    if (collapsed) collapsedBooks.add(assetID); else collapsedBooks.delete(assetID);
    renderLibrary();
    invoke("setBookCollapsed", {assetID,collapsed});
  }

  // ---------- 渲染：侧栏 ----------

  function renderSidebar() {
    renderSidebarLayout();
    renderNowReading();
    renderLibrary();
    renderSettingsBadge();
  }

  function renderNowReading() {
    const d = state.detected;
    $("identify-book-btn").hidden = state.detectionState !== "ambiguousBook";

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
    {id:"summary", command:"summary", label:"全书摘要", hint:"查看进度、结果，或手动生成"},
    {id:"new", command:"new", label:"新建对话", hint:"为当前书籍开始新的对话"},
    {id:"generate", label:"生成全书摘要"},
    {id:"cancelSummary", label:"取消摘要生成"},
    {id:"clearSummary", label:"清除摘要"},
    {id:"regenerate", label:"重新生成"},
  ];
  let commandMatches = [], commandIndex = 0;
  let menuAnchor = null;
  function feedback(text) { $("command-feedback").textContent = text; $("command-feedback").hidden = false; }
  function actionDisabled(id) {
    if (id === "new") return !state.active?.assetID || chatState.streaming;
    if (["summary", "generate", "cancelSummary", "clearSummary", "regenerate"].includes(id)) {
      if (!state.active?.assetID) return true;
      if (id === "summary") return false;
      if (id === "cancelSummary") return !chatState.summaryRunning;
      if (id === "clearSummary") return !chatState.hasSharedSummary && !chatState.summaryRunning;
      return chatState.summaryRunning || !(window.ModelManager?.summaryReady ?? settingsState.settings?.isConfigured);
    }
    if (!hasConversation() || chatState.refreshingPosition) return true;
    if (state.active?.archived) return true;
    if (chatState.streaming) return true;
    return false;
  }
  function renderActionAvailability() {
    $("actions-btn").disabled = !state.active?.assetID;
    for (const el of document.querySelectorAll("[data-action]")) {
      const id = el.dataset.action; el.disabled = actionDisabled(id);
    }
    $("range-mode").textContent = `读取模式：${settingsState.knowledgeScopes.find(s => s.id === (state.active?.scope || chatState.scope))?.label ?? "尚未选择"}${state.active?.scope ? " · 本对话已固定" : " · 首次提问后固定"}`;
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
  let chapterStructure = null;
  let pendingStructureAction = null;
  function renderStructure(value) {
    chapterStructure = value;
    $("structure-status").textContent = value?.status || "请先读取本地书籍";
    $("structure-issues").textContent = value?.issues || "未检测到明显结构问题，可按需检查。";
    $("structure-analyze").disabled = !value || value.running || chatState.streaming;
    $("structure-cancel").hidden = !value?.running;
    $("structure-restore").hidden = !value?.applied;
    $("structure-apply").hidden = !value?.proposalID;
    $("structure-discard").hidden = !value?.proposalID;
    $("structure-scope").hidden = !(value?.structureChanged && !value?.scopeConfirmed && (state.active?.scope || chatState.scope) === "currentChapter");
    $("structure-preview").replaceChildren();
    if (value?.proposalID) {
      const counts = document.createElement("p");
      counts.textContent = `当前 ${value.oldCount} 个区段 → 建议 ${value.newCount} 个区段；${value.uncertain} 个不确定节点，请核对。范围外标题已隐藏。`;
      $("structure-preview").append(counts);
      for (const text of value.rows || []) { const row = document.createElement("p"); row.className = "chapter-stat-row"; row.textContent = text; $("structure-preview").append(row); }
    }
  }
  function confirmStructureAction(action) {
    if (!chapterStructure) return;
    pendingStructureAction = {action, payload:{assetID:chapterStructure.assetID, conversationID:chapterStructure.conversationID,
      version:chapterStructure.version, proposalID:chapterStructure.proposalID, confirmed:true}};
    const text = {
      analyzeStructure: ["分析全书章节结构？", `将全书候选标题、层级、位置和每个候选附近最多 160 个非空白字符（可能包含未读内容）发送至 ${window.ModelManager?.summaryName || "所选摘要模型"} 对应的接口 分批分析，会产生 API 用量。每批遵守所设上下文预算。结果仅作为结构建议，不进入聊天上下文；不会自动生成摘要或改变阅读权限。`],
      applyStructure: ["应用这份章节方案？", "书籍下所有对话共享新结构。保留边界和正文未变的章节摘要，其余章节及全书摘要重新生成。运行中的回答和摘要将停止。整章模式的对话需分别确认新的读取范围；读到这里的原文位置不变。"],
      restoreStructure: ["恢复本地章节结构？", "恢复由原书目录和标题构建的章节地图。会停止正在进行的回答和摘要，清理失效摘要，整章对话需要重新确认范围。Apple Books 原书不变。"],
      confirmStructureScope: ["确认本对话新的整章范围？", "本对话将按照当前章节统计读取：当前所在章节的完整内容及之前全部章节。这可能比原结构包含更多未读文字。请先核对章节统计；确认仅对本对话及当前结构版本生效。"]
    }[action];
    $("structure-confirm-title").textContent = text[0]; $("structure-confirm-text").textContent = text[1];
    $("structure-confirm").showModal(); $("structure-no").focus();
  }
  let summaryTarget = null;
  function openPanel(kind) {
    if (kind === "summary") {
      showView("chat");
      $("summary-document").hidden = false; els.viewChat.classList.add("show-summary");
      $("summary-book-title").textContent = state.library.find(b => b.assetID === state.active?.assetID)?.title || "";
      renderPreparation(); return;
    }
    $("range-panel").hidden = false;
    if (!$("reading-panel").open) $("reading-panel").showModal();
  }
  function closeSummary() { $("summary-document").hidden = true; els.viewChat.classList.remove("show-summary"); }
  function runAction(id) {
    if (actionDisabled(id)) { feedback("当前状态下无法执行此操作。"); return; }
    closeMenus(); hideCommands(); $("command-feedback").hidden = true;
    switch (id) {
      case "now":
        chatState.refreshingPosition = true;
        showPosition("正在刷新阅读位置…"); renderComposerState();
        invoke("refreshPosition"); break;
      case "select":
        feedback("正在读取 Books 中的划选…"); invoke("captureSelection"); break;
      case "scope":
        $("reading-check-result").textContent = "正在检查本地正文与当前页…";
        openPanel("scope"); invoke("checkReading", {scope:state.active?.scope || chatState.scope}); break;
      case "summary": openPanel("summary"); break;
      case "generate":
      case "regenerate":
        invoke("reprocessBook", {confirmed:true, restart:id === "regenerate"});
        openPanel("summary"); break;
      case "cancelSummary": invoke("cancelPreparation"); break;
      case "clearSummary":
        $("prepare-confirm").dataset.action = "clear"; $("prepare-title").textContent = "清除全书摘要？";
        $("prepare-destination").textContent = "将取消本书摘要任务，清除全部章节摘要和全书摘要，影响本书所有对话。章节统计和 Apple Books 原书保留。";
        $("prepare-yes").textContent = "清除摘要"; $("prepare-confirm").showModal(); $("prepare-no").focus(); break;
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
  let pendingManagement = null, sourceDialogState = null, managementSequence = 0;
  function manage(kind, book, conversation = null) {
    closeMenus();
    const deleting = kind === "deleteBook" || kind === "deleteConversation";
    const title = conversation?.title ?? book.title;
    pendingManagement = {type:kind === "deleteBook" ? "removeBook" : kind,
      assetID:book.assetID, ...(conversation ? {conversationID:conversation.id} : {}), requestID:`management-${Date.now()}-${++managementSequence}`};
    $("management-title").textContent = `${deleting ? "删除" : "重命名"}${conversation ? "对话" : "书籍"}`;
    $("management-description").textContent = deleting
      ? (conversation ? `确定删除「${title}」？\n将永久删除本对话的消息、思考内容、阅读快照和旧版对话摘要。书籍共享摘要、书籍与其他对话保留，此操作不可撤销。`
        : `确定删除《${title}》？\n将永久删除 BooksBridge 中该书的资料、章节地图、摘要文档与缓存，以及全部下属对话（包括已归档）、消息和思考内容。\nApple Books 中的原书文件保留。此操作不可撤销。`)
      : (conversation ? "留空可恢复按阅读位置和时间自动命名。" : `原书名：${book.originalTitle ?? book.title}\n仅修改 BooksBridge 中的显示名称；留空可恢复原名。`);
    $("management-name-field").hidden = deleting;
    $("management-name").value = title;
    $("management-confirm").textContent = deleting ? "删除" : "保存";
    $("management-confirm").classList.toggle("danger", deleting);
    $("management-confirm").disabled = false; $("management-confirm").hidden = false;
    $("management-cancel").disabled = false; $("management-cancel").textContent = "取消";
    $("management-error").hidden = true;
    $("management-dialog").showModal();
    if (deleting) $("management-cancel").focus(); else { $("management-name").focus(); $("management-name").select(); }
  }
  $("management-form").addEventListener("submit", event => {
    event.preventDefault();
    if (!pendingManagement || $("management-confirm").disabled) return;
    $("management-confirm").disabled = true; $("management-cancel").disabled = true;
    const {type,...payload} = pendingManagement;
    invoke(type, {...payload, title:$("management-name").value.trim(), confirmed:true});
  });
  $("management-cancel").addEventListener("click", () => $("management-dialog").close());
  $("management-dialog").addEventListener("cancel", event => { if ($("management-confirm").disabled) event.preventDefault(); });
  $("management-dialog").addEventListener("close", () => { pendingManagement = null; });

  $("identify-book-btn").addEventListener("click", () => invoke("identifyActiveBook"));
  function showBookSource(kind, data) {
    sourceDialogState = {kind,...data};
    const duplicate = kind === "duplicate";
    $("book-source-title").textContent = duplicate ? "检测到相同的书籍文件" : "确认当前书籍";
    $("book-source-description").textContent = duplicate
      ? `《${data.title}》与已有书籍的文件相同。可关联已有记录，沿用其对话与自定义名称；也可独立添加。`
      : `当前窗口：${data.windowTitle}。请选择正在阅读的原书文件。此确认仅对当前页面有效，页面变化后会重新核对。`;
    const select = $("book-source-select"); select.replaceChildren();
    for (const book of data.matches ?? data.books ?? []) {
      const option = document.createElement("option"); option.value = book.assetID;
      option.textContent = `${book.title}${book.author ? " · " + book.author : ""}${book.conversationCount !== undefined ? " · " + book.conversationCount + " 个对话" : ""}${book.path ? " · " + book.path.split('/').slice(-2).join('/') : ""}`;
      select.append(option);
    }
    $("book-source-separate").hidden = !duplicate;
    $("book-source-confirm").textContent = duplicate ? "关联已有书籍" : "确认书籍";
    $("book-source-confirm").disabled = select.options.length === 0;
    updateBookSourcePath(); $("book-source-dialog").showModal();
  }
  function updateBookSourcePath() {
    const books = sourceDialogState?.books ?? sourceDialogState?.matches ?? [];
    $("book-source-path").textContent = books.find(book => book.assetID === $("book-source-select").value)?.path ?? "";
  }
  $("book-source-select").addEventListener("change", updateBookSourcePath);
  function finishBookSource(choice) {
    if (!sourceDialogState) return;
    const {kind,requestID} = sourceDialogState;
    sourceDialogState = null; $("book-source-dialog").close();
    if (kind === "duplicate") invoke("resolveSourceImport", {requestID,...choice});
    else if (choice.assetID) invoke("confirmActiveBook", {requestID,assetID:choice.assetID});
  }
  $("book-source-cancel").addEventListener("click", () => finishBookSource({cancelled:true}));
  $("book-source-dialog").addEventListener("cancel", event => { event.preventDefault(); finishBookSource({cancelled:true}); });
  $("book-source-confirm").addEventListener("click", () => finishBookSource({assetID:$("book-source-select").value}));
  $("book-source-separate").addEventListener("click", () => finishBookSource({separate:true}));
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
      el.classList.toggle("danger", !!item.danger);
      el.disabled = !!item.disabled; el.setAttribute("role", "menuitem"); menu.append(el);
    }
    showMenu(menu, anchor); menu.querySelector("button:not(:disabled)")?.focus();
  }
  function renderLibrary() {
    const signature = JSON.stringify([state.library, state.active?.assetID, state.active?.conversationID, [...collapsedBooks].sort()]);
    if (signature === librarySignature || draggingBook) return;
    librarySignature = signature;
    const focusedBook = document.activeElement?.closest('.book-disclosure')?.dataset.assetId;
    const list = els.libraryList; list.replaceChildren();
    els.libraryEmpty.hidden = state.library.length > 0;
    for (const [index, book] of state.library.entries()) {
      const group = document.createElement("div"); group.className = "book-group";
      group.dataset.assetId = book.assetID;
      const bookRow = document.createElement("div"); bookRow.className = "book-row";
      bookRow.draggable = true; bookRow.title = "拖动调整书籍顺序";
      const collapsed = collapsedBooks.has(book.assetID);
      const disclosure = button("", "icon-btn book-disclosure", () => setBookCollapsed(book.assetID, !collapsed));
      disclosure.innerHTML = '<svg viewBox="0 0 12 12" aria-hidden="true"><path d="m3 4.5 3 3 3-3"/></svg>';
      disclosure.dataset.assetId = book.assetID;
      disclosure.setAttribute("aria-expanded", String(!collapsed));
      disclosure.setAttribute("aria-controls", `book-conversations-${index}`);
      disclosure.setAttribute("aria-label", `${collapsed ? "展开" : "折叠"}《${book.title}》的对话`);
      disclosure.title = collapsed ? "展开对话" : "折叠对话";
      const title = button(book.title, "book-title", () => invoke("openBook", {assetID: book.assetID}));
      title.title = book.title;
      const add = button("＋", "icon-btn row-action", () => invoke("newConversation", {assetID: book.assetID}));
      add.setAttribute("aria-label", `为《${book.title}》新建对话`); add.title = "新建对话";
      const more = button("⋯", "icon-btn row-action", () => sidebarMenu(more, [
        {label:"上移", disabled:index === 0, run:() => moveRelative(book.assetID, -1)},
        {label:"下移", disabled:index === state.library.length - 1, run:() => moveRelative(book.assetID, 1)},
        {label:"全书摘要", run:() => { summaryTarget = book.assetID; invoke("openBook", {assetID:book.assetID}); if (state.active?.assetID === book.assetID) { openPanel("summary"); summaryTarget = null; } }},
        {label:"重命名", run:() => manage("renameBook", book)},
        {label:"删除书籍", danger:true, run:() => manage("deleteBook", book)},
      ]));
      more.setAttribute("aria-label", `《${book.title}》的操作`); more.setAttribute("aria-haspopup", "menu");
      bookRow.append(disclosure, title, add, more);
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
      convList.id = `book-conversations-${index}`; convList.hidden = collapsed;
      for (const conversation of book.conversations.filter(c => !c.archived)) {
        const wrap = document.createElement("div"); wrap.className = "conversation-row";
        const row = button(conversation.title, "conv-row", () => invoke("selectConversation", {assetID:book.assetID, conversationID:conversation.id}));
        if (els.viewSettings.hidden && state.active?.assetID === book.assetID && state.active?.conversationID === conversation.id) wrap.classList.add("active");
        row.title = conversation.title;
        const badge = document.createElement("span"); badge.className = "cc";
        badge.textContent = conversation.summaryStatus?.startsWith("正在") ? "◌" : "";
        badge.title = conversation.summaryStatus || "";
        const more = button("⋯", "icon-btn row-action", () => sidebarMenu(more, [
          {label:"归档对话", run:() => invoke("archiveConversation", {assetID:book.assetID, conversationID:conversation.id})},
          {label:"重命名", run:() => manage("renameConversation", book, conversation)},
        ]));
        more.setAttribute("aria-label", `${conversation.title}的操作`); more.setAttribute("aria-haspopup", "menu");
        wrap.append(row, more); convList.append(wrap);
      }
      group.append(bookRow, convList); list.append(group);
    }
    if (focusedBook && !sidebarCollapsed) [...list.querySelectorAll('.book-disclosure')].find(el => el.dataset.assetId === focusedBook)?.focus({preventScroll:true});
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
        const view = button(c.title, "archive-title", () => { invoke("selectConversation", {assetID:book.assetID, conversationID:c.id}); });
        const restore = button("恢复", "btn-plain", () => { invoke("restoreConversation", {assetID:book.assetID, conversationID:c.id}); });
        const rename = button("重命名", "btn-plain", () => manage("renameConversation", book, c));
        const remove = button("删除", "btn-plain danger", () => manage("deleteConversation", book, c));
        remove.dataset.archiveAction = "delete"; rename.dataset.archiveAction = "rename";
        row.append(view, restore, rename, remove); list.append(row);
      }
    }
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
      els.crumbConv.title = els.crumbConv.textContent; els.crumbBook.title = activeBook.title;

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
    wrap.dataset.assetId = state.active?.assetID ?? '';
    wrap.dataset.conversationId = state.active?.conversationID ?? '';

    const roleLabel = document.createElement("div");
    roleLabel.className = "msg-role";
    roleLabel.textContent = options.roleLabel ?? (role === "user" ? "我" : window.ModelManager?.chatName ?? "助手");
    wrap.append(roleLabel);

    if (options.reasoning) {
      const details = document.createElement("details");
      details.className = "msg-reasoning";
      details.open = options.reasoningExpanded ?? (settingsState.settings?.autoExpandReasoning === true);
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
    bindReasoning(wrap, options.reasoningExpanded);
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
  function bindReasoning(wrap, explicitChoice) {
    const details = wrap.querySelector('.msg-reasoning');
    if (!details) return;
    if (explicitChoice != null) details.dataset.manual = 'true';
    if (details.dataset.bound) return;
    details.dataset.bound = 'true'; details.dataset.expanded = String(details.open);
    const saveChoice = () => {
      if (details.dataset.expanded === String(details.open) || !wrap.isConnected) return;
      details.dataset.expanded = String(details.open); details.dataset.manual = 'true';
      const payload = {assetID:wrap.dataset.assetId, conversationID:wrap.dataset.conversationId, expanded:details.open};
      if (chatState.streaming && chatState.streamNode?.closest('.msg') === wrap) {
        invoke('setPendingReasoningExpanded', payload);
      } else if (wrap.dataset.messageId) {
        invoke('setReasoningExpanded', {...payload, messageID:wrap.dataset.messageId});
      }
    };
    // Native toggle events are queued; persist the click before navigation/archiving can remove the node.
    details.querySelector('summary').addEventListener('click', event => {
      event.preventDefault(); details.open = !details.open; saveChoice();
    });
    details.addEventListener('toggle', saveChoice);
  }
  function attachMessageActions(wrap, message) {
    wrap.dataset.messageId = message.id || "";
    wrap.dataset.rawText = message.text;
    wrap.dataset.positionCard = String(!!message.isPositionCard);
    bindReasoning(wrap, message.reasoningExpanded);
    const reasoning = wrap.querySelector('.msg-reasoning');
    if (message.id && message.reasoning && reasoning?.dataset.manual === 'true' && message.reasoningExpanded !== reasoning.open) {
      invoke('setReasoningExpanded', {...messagePayload(message.id), expanded:reasoning.open});
    }
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
    wrap.replaceWith(original);
    if (original.querySelector('.msg-reasoning')) delete original.querySelector('.msg-reasoning').dataset.bound;
    attachMessageActions(original,message); retryBackup = null;
  }
  function compactPosition(text) {
    if (/未定位|未取得有效/.test(text)) return "当前位置未定位";
    return text.replace(/ · 已刷新/g, "").replace(/ · \d{1,2}:\d{2}(?::\d{2})?(?:\s*[AP]M)?/g, "");
  }
  function positionNode(text, id) {
    const node = document.createElement("div"); node.className = "position-marker";
    node.textContent = compactPosition(text); node.dataset.rawText = text;
    if (id) node.dataset.messageId = id;
    return node;
  }
  function showPosition(text, beforeUser = false) {
    const user = beforeUser ? chatState.streamNode?.closest('.msg')?.previousElementSibling : null;
    const adjacent = user?.classList.contains('user') ? user.previousElementSibling : els.messages.lastElementChild;
    const node = positionNode(text);
    if (adjacent?.classList.contains('position-marker')) adjacent.replaceWith(node);
    else if (user?.classList.contains('user')) els.messages.insertBefore(node, user);
    else els.messages.append(node);
    scrollToBottom();
  }
  function syncMessages() {
    if (chatState.streaming) return;
    const messages = state.active?.messages ?? [];
    const signature = JSON.stringify(messages);
    if (signature === renderedMessagesSignature) return;
    renderedMessagesSignature = signature;
    const existing = [...els.messages.querySelectorAll('.msg, .position-marker')];
    for (const message of messages) {
      if (message.isPositionCard) {
        if (message.role === 'user') continue; // Legacy /now commands are not chat messages.
        const old = existing.find(el => el.dataset.messageId === message.id);
        if (old) existing.splice(existing.indexOf(old), 1);
        const node = positionNode(message.text, message.id);
        old?.remove(); els.messages.append(node); continue;
      }
      let wrap = existing.find(el => message.id && el.dataset.messageId === message.id);
      if (!wrap) wrap = existing.find(el => !el.dataset.messageId && el.classList.contains(message.role) && (el.dataset.rawText ?? el.querySelector('.msg-body')?.textContent) === message.text);
      if (!wrap || (wrap.dataset.rawText !== undefined && wrap.dataset.rawText !== message.text)) {
        wrap = appendMessage(message.role, message.text, {roleLabel: message.role === 'user' ? '我' : message.modelName ?? '助手', reasoning:message.reasoning, reasoningExpanded:message.reasoningExpanded}).closest('.msg');
      }
      const index = existing.indexOf(wrap); if (index >= 0) existing.splice(index,1);
      wrap.querySelector('.msg-role').textContent = message.role === 'user' ? '我' : message.modelName ?? '助手';
      attachMessageActions(wrap,message); els.messages.append(wrap);
    }
    existing.forEach(el => el.remove());
    for (const marker of [...els.messages.querySelectorAll('.position-marker')]) {
      if (marker.nextElementSibling?.classList.contains('position-marker')) marker.remove();
    }
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

  let summaryStatistics = null;
  function renderPreparation() {
    const stats = summaryStatistics;
    const complete = chatState.preparationReady;
    const running = chatState.summaryRunning;
    const completed = stats?.completed || 0, total = stats?.chapters?.length || 0;
    const failed = chatState.preparationFailed;
    const status = complete ? "已完成" : running ? (total && completed === total ? "正在汇总全书" : total ? `正在生成 · 已完成 ${completed} / ${total}` : "正在读取书籍…")
      : failed ? "生成失败 · 已完成章节保留" : completed ? `未完成 · ${completed} / ${total}` : "尚未生成";
    els.prepBar.hidden = false; els.prepText.textContent = status;
    $("summary-status").textContent = complete ? "已完成" : running ? (total ? `生成中 ${completed}/${total}` : "准备中") : completed ? "未完成" : "";
    $("summary-progress").hidden = !running;
    $("summary-progress").max = Math.max(1, total + 1); $("summary-progress").value = completed;
    els.prepRetry.hidden = running || complete;
    els.prepRetry.disabled = actionDisabled("generate");
    els.prepRetry.textContent = completed ? "继续生成" : "生成全书摘要";
    $("prep-cancel").hidden = !running;
    $("summary-metadata").textContent = failed ? chatState.preparation : complete ? "" : "概括全书内容，包含结局与后续情节。";
    $("summary-book-title").textContent = state.library.find(b => b.assetID === state.active?.assetID)?.title || "";
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
    window.ModelManager?.renderSelection(chatState.streaming, chatState.summaryRunning);
    renderPreparation();
  }

  // ---------- 渲染：发送状态 ----------

  function renderComposerState() {
    const configured = (window.ModelManager?.chatReady ?? settingsState.settings?.isConfigured ?? false);
    const localCommand = /^\/(now|select|scope|summary|new)\s*$/.test(els.input.value.trim());
    const canSend = (configured || localCommand) && hasConversation() && !chatState.streaming && !chatState.refreshingPosition
      && !state.active?.archived && els.input.value.trim().length > 0 && (localCommand || !selectedQuote || $("selection-confirmed").checked);

    els.sendBtn.disabled = !canSend;
    els.sendBtn.hidden = chatState.streaming;
    els.cancelBtn.hidden = !chatState.streaming;
    els.input.disabled = !hasConversation() || !!state.active?.archived;
    $("archive-banner").hidden = !state.active?.archived;
    renderActionAvailability();
    renderMessageActions();

    if (!configured) {
      els.input.placeholder = "输入 / 使用阅读命令；提问前请选择可用模型";
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
          bindReasoning(chatState.streamNode.closest(".msg"));
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

    if (!settingsState.dirty) {
      els.setScope.value = s.defaultScope;
      $("set-auto-expand-reasoning").checked = s.autoExpandReasoning === true;
      els.setMaxTokens.value = String(s.maxContextCharacters);
    }
    const scopeInfo = settingsState.knowledgeScopes.find(x => x.id === s.defaultScope);
    if (scopeInfo) $("set-scope-hint").textContent = scopeInfo.explanation;
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
    if (name !== activeSection) collectAndSave();
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
    if (!toSettings && !els.viewSettings.hidden) collectAndSave();
    closeMenus(); hideCommands();
    els.viewChat.hidden = toSettings;
    els.viewSettings.hidden = !toSettings;
    document.querySelectorAll(".nav-item").forEach((b) => b.classList.remove("active"));
    if (toSettings) showSection(activeSection);
    els.settingsBtn.classList.toggle('active', toSettings);
    els.settingsBtn.setAttribute('aria-pressed', String(toSettings));
    librarySignature = ''; renderLibrary();
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
    pendingStructureAction = null;
    for (const id of ["reading-panel", "prepare-confirm", "structure-confirm"]) if ($(id).open) $(id).close();
    els.input.value = ""; autoGrow();
    $("command-feedback").hidden = true;
    closeSummary(); summaryStatistics = null; chatState.refreshingPosition = false;
    chatState.streaming = false;
    document.getElementById("reading-check-result").textContent = "";
    chatState.preparation = ""; chatState.preparationReady = false; chatState.preparationFailed = false; chatState.hasSharedSummary = false;
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
      window.ModelManager?.receive(payload);
      if (payload.sourceImport) showBookSource("duplicate", payload.sourceImport);
      if (payload.bookIdentification) showBookSource("identify", payload.bookIdentification);
      if (payload.managementResult) {
        const result = payload.managementResult;
        if (pendingManagement?.requestID === result.requestID) {
          if (result.success) $("management-dialog").close();
          else {
            $("management-error").textContent = result.message; $("management-error").hidden = false;
            $("management-confirm").disabled = false; $("management-cancel").disabled = false;
            if (result.recordRemoved) { $("management-confirm").hidden = true; $("management-cancel").textContent = "关闭"; }
          }
        }
        feedback(result.message);
      }
      if (payload.sidebarLayout) {
        if (typeof payload.sidebarLayout.collapsed === "boolean") sidebarCollapsed = payload.sidebarLayout.collapsed;
        if (Array.isArray(payload.sidebarLayout.collapsedBooks)) collapsedBooks = new Set(payload.sidebarLayout.collapsedBooks);
        if (!sidebarResize && Number.isFinite(payload.sidebarLayout.width)) sidebarPreferredWidth = Math.round(Math.max(sidebarMinWidth, Math.min(sidebarMaxWidth, payload.sidebarLayout.width)));
      }
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
        for (const details of document.querySelectorAll('.msg-reasoning')) {
          if (details.dataset.manual !== 'true') {
            details.dataset.expanded = String(payload.settings.autoExpandReasoning === true);
            details.open = payload.settings.autoExpandReasoning === true;
          }
        }
      }
      if (Array.isArray(payload.providers)) settingsState.providers = payload.providers;
      if (Array.isArray(payload.knowledgeScopes)) settingsState.knowledgeScopes = payload.knowledgeScopes;
      if (Array.isArray(payload.thinkingLevels)) settingsState.thinkingLevels = payload.thinkingLevels;
      if (payload.permissionProbe) settingsState.permissionProbe = payload.permissionProbe;

      if (payload.openSettings) showView("settings");

      // 会话历史：仅在切换会话时整段重绘，避免与流式渲染互相打架
      if (payload.active !== undefined) syncConversation();

      // 问答事件（流式增量等）
      if (payload.chatEvent) handleChatEvent(payload.chatEvent);
      if (payload.messageActionError) appendError(payload.messageActionError);

      if (payload.readingPosition !== undefined) {
        $("range-position").textContent = payload.readingPosition;
      }
      if (payload.positionDivider) showPosition(payload.positionDivider, true);
      if (payload.positionRefreshFinished || (chatState.refreshingPosition && payload.chatEvent?.kind === "error")) {
        chatState.refreshingPosition = false; renderedMessagesSignature = null;
        if (payload.positionRefreshError) { showPosition("当前位置未定位"); feedback(payload.positionRefreshError); }
      }
      if (payload.assistant) chatState.hasSharedSummary = payload.assistant.hasSharedSummary === true;
      if (payload.bookStatistics !== undefined) {
        const stats = payload.bookStatistics; summaryStatistics = stats;
        $("book-statistics").textContent = stats ? `约 ${stats.characters.toLocaleString()} 字 · ${stats.chapterCount ?? stats.chapters.length} 章` : "正在读取本地书籍…";
        $("chapter-statistics-list").replaceChildren();
        for (const chapter of stats?.chapters || []) {
          const row = document.createElement("p"); row.className = "chapter-stat-row";
          row.textContent = `${chapter.number}. ${chapter.title} · ${chapter.complete ? "已完成" : "未生成"}`;
          $("chapter-statistics-list").append(row);
        }
      }
      if (payload.chapterStructure !== undefined) renderStructure(payload.chapterStructure);
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
        chatState.summaryRunning = payload.assistant.running === true;
        chatState.preparation = payload.assistant.preparation ?? "";
        chatState.preparationReady = payload.assistant.ready === true;
        chatState.preparationFailed = /失败/.test(chatState.preparation);
      }

      if (summaryTarget && state.active?.assetID === summaryTarget) { summaryTarget = null; openPanel("summary"); }
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
      providerOptions: document.querySelectorAll(".service-item").length,
      scopeOptions: els.setScope.options.length,
      modelValue: window.ModelManager?.chatName ?? "",
      scopeValue: els.setScope.value,
      hasAPIKey: settingsState.settings?.hasAPIKey ?? false,
      isConfigured: (window.ModelManager?.chatReady ?? settingsState.settings?.isConfigured ?? false),
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
    if (els.viewSettings.hidden) { showView("settings"); invoke("getSettings"); }
    else showView("chat");
  });


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
    if (!question || chatState.streaming || chatState.refreshingPosition || !hasConversation() || state.active?.archived) return;
    const command = question.match(/^\/([^\s]+)(?:\s+([\s\S]*))?$/);
    if (command && !(command[1] === "now" && command[2]?.trim())) {
      const action = actions.find(a => a.command === command[1]);
      if (!action || command[2]?.trim()) { feedback("未识别的命令。输入 / 查看可用命令；仅 /now 支持附带问题。"); return; }
      if (actionDisabled(action.id)) { feedback("当前状态下无法执行此操作。"); return; }
      els.input.value = ""; autoGrow(); hideCommands(); renderComposerState(); runAction(action.id); return;
    }
    if (!((window.ModelManager?.chatReady ?? settingsState.settings?.isConfigured ?? false))) { feedback("请先在设置中配置模型接口。"); return; }
    if (selectedQuote && !document.getElementById("selection-confirmed").checked) return;
    appendMessage("user", question.replace(/^\/now\s+/, "") + (selectedQuote ? "\n\n引用：\n" + selectedQuote.text : ""), { roleLabel: "我" });
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
    renderStructure(chapterStructure);
  });
  document.querySelectorAll("[data-action]").forEach(el => el.addEventListener("click", () => runAction(el.dataset.action)));
  $("summary-back").addEventListener("click", closeSummary);
  $("summary-more").addEventListener("click", () => sidebarMenu($("summary-more"), [
    {label:"重新生成", disabled:actionDisabled("regenerate"), run:() => runAction("regenerate")},
    {label:"清除摘要", disabled:actionDisabled("clearSummary"), run:() => runAction("clearSummary")},
  ]));
  $("prepare-yes").addEventListener("click", () => {
    const action = $("prepare-confirm").dataset.action;
    $("prepare-confirm").close();
    if (action === "clear") invoke("clearKnowledge", {confirmed:true});
    else invoke("reprocessBook", {confirmed:true});
    openPanel("summary");
  });
  $("prepare-no").addEventListener("click", () => $("prepare-confirm").close());
  for (const [id, action] of [["analyze","analyzeStructure"],["apply","applyStructure"],["restore","restoreStructure"],["scope","confirmStructureScope"]]) {
    $("structure-" + id).addEventListener("click", () => confirmStructureAction(action));
  }
  $("structure-cancel").addEventListener("click", () => { if (chapterStructure) invoke("cancelStructure", {assetID:chapterStructure.assetID}); });
  $("structure-discard").addEventListener("click", () => { if (chapterStructure) invoke("discardStructure", {assetID:chapterStructure.assetID, proposalID:chapterStructure.proposalID}); });
  $("structure-no").addEventListener("click", () => { pendingStructureAction = null; $("structure-confirm").close(); });
  $("structure-yes").addEventListener("click", () => {
    if (pendingStructureAction) invoke(pendingStructureAction.action, pendingStructureAction.payload);
    pendingStructureAction = null; $("structure-confirm").close();
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

  for (const el of [els.setScope, els.setMaxTokens, $("set-auto-expand-reasoning")]) {
    el.addEventListener("input", () => { settingsState.dirty = true; });
    el.addEventListener("change", () => { settingsState.dirty = true; });
  }
  function collectAndSave() {
    if (!settingsState.dirty) return;
    invoke("saveSettings", {
      defaultScope: els.setScope.value,
      autoExpandReasoning: $("set-auto-expand-reasoning").checked,
      maxContextCharacters: Number(els.setMaxTokens.value) || 12000,
    });
    settingsState.dirty = false;
  }

  window.ModelManager?.init({ invoke, feedback, context: () => ({ active: state.active, streaming: chatState.streaming, summaryRunning: chatState.summaryRunning }) });

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

  // 原生拖动层只接管顶栏空白和标题，保留按钮的点击与悬停。
  let titlebarSignature = "";
  function syncTitlebarHitRegions() {
    const rect = el => {
      const {x,y,width,height} = el.getBoundingClientRect();
      return {x,y,width,height:Math.min(height, parseFloat(getComputedStyle(document.documentElement).getPropertyValue('--topbar-h')))};
    };
    const visible = el => el.getClientRects().length > 0;
    const modalOpen = !!document.querySelector('dialog[open]');
    const payload = {
      draggable: modalOpen ? [] : [...document.querySelectorAll('.side-head,.topbar')].filter(visible).map(rect),
      interactive: [...document.querySelectorAll('#sidebar-toggle,#sidebar-resizer,.topbar button,.topbar select,.topbar input')].filter(visible).map(rect),
    };
    const signature = JSON.stringify(payload);
    if (signature !== titlebarSignature) { titlebarSignature = signature; invoke('setTitlebarHitRegions', payload); }
  }
  const titlebarObserver = new ResizeObserver(syncTitlebarHitRegions);
  document.querySelectorAll('#sidebar-toggle,.side-head,.topbar,.topbar button,.topbar .crumb,.reading-status').forEach(el => titlebarObserver.observe(el));
  const titlebarModalObserver = new MutationObserver(syncTitlebarHitRegions);
  document.querySelectorAll('dialog').forEach(el => titlebarModalObserver.observe(el, {attributes:true,attributeFilter:['open']}));
  window.addEventListener('resize', syncTitlebarHitRegions);

  invoke("ready");
})();
