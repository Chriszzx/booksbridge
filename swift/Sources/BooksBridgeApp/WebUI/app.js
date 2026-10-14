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

  function renderLibrary() {
    const list = els.libraryList;
    list.textContent = "";

    if (state.library.length === 0) {
      els.libraryEmpty.hidden = false;
      return;
    }
    els.libraryEmpty.hidden = true;

    for (const book of state.library) {
      const group = document.createElement("div");
      group.className = "book-group";

      // 书行：整行可点，进入这本书；右侧 ＋ 新建对话
      const bookRow = document.createElement("div");
      bookRow.className = "book-row";
      bookRow.tabIndex = 0;

      const title = document.createElement("span");
      title.className = "bt";
      title.textContent = book.title;
      title.title = book.title;

      const count = document.createElement("span");
      count.className = "bc";
      count.textContent = String(book.conversations.length);

      const addButton = document.createElement("button");
      addButton.className = "icon-btn row-add";
      addButton.title = "新建对话";
      addButton.textContent = "＋";
      addButton.addEventListener("click", (event) => {
        event.stopPropagation();
        invoke("newConversation", { assetID: book.assetID });
      });

      bookRow.append(title, count, addButton);
      bookRow.addEventListener("click", () => {
        invoke("openBook", { assetID: book.assetID });
      });

      const convList = document.createElement("div");
      convList.className = "conv-list";
      for (const conversation of book.conversations) {
        const row = document.createElement("button");
        row.className = "conv-row";
        const isActive =
          state.active?.assetID === book.assetID &&
          state.active?.conversationID === conversation.id;
        if (isActive) row.classList.add("active");

        const label = document.createElement("span");
        label.className = "ct";
        label.textContent = conversation.title;

        const badge = document.createElement("span");
        badge.className = "cc";
        badge.textContent = conversation.messageCount > 0 ? String(conversation.messageCount) : "";

        row.append(label, badge);
        row.addEventListener("click", () => {
          invoke("selectConversation", {
            assetID: book.assetID,
            conversationID: conversation.id,
          });
        });
        convList.append(row);
      }

      group.append(bookRow, convList);
      list.append(group);
    }
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
    return !!state.active?.assetID;
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
      const summary = document.createElement("summary");
      summary.textContent = "思考过程";
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
    const canSend = configured && hasConversation() && !chatState.streaming
      && els.input.value.trim().length > 0;

    els.sendBtn.disabled = !canSend;
    els.sendBtn.hidden = chatState.streaming;
    els.cancelBtn.hidden = !chatState.streaming;
    els.input.disabled = !configured || !hasConversation();

    if (!configured) {
      els.input.placeholder = "请先在「设置 → 模型与 API」里填写 API Key";
    } else if (!hasConversation()) {
      els.input.placeholder = "先在左侧选择一本书";
    } else {
      els.input.placeholder = "就正在读的内容提问…（Enter 发送，Shift+Enter 换行）";
    }
  }

  // ---------- 流式事件 ----------

  function handleChatEvent(event) {
    switch (event.kind) {
      case "reasoning":
        if (!chatState.streamNode) startAssistantMessage();
        if (chatState.streamReasoning) {
          chatState.streamReasoning.textContent += event.text;
        } else {
          // 首次出现思考内容时补一个折叠块
          const details = document.createElement("details");
          details.className = "msg-reasoning";
          const summary = document.createElement("summary");
          summary.textContent = "思考过程";
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
    chatState.streamNode = appendMessage("assistant", "");
    showCursor(true);
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
  let renderedConversationKey = null;

  /** 切换会话时把历史消息整段重绘。 */
  function syncConversation() {
    const key = state.active
      ? `${state.active.assetID}/${state.active.conversationID ?? ""}`
      : "";
    chatState.scope = state.active?.scope ?? (key !== renderedConversationKey
      ? settingsState.settings?.defaultScope ?? "upToProgress" : chatState.scope);
    renderScopePicker();
    // 会话没变就不动 DOM——流式渲染正在进行时更不能重绘
    if (key === renderedConversationKey) return;
    renderedConversationKey = key;
    chatState.streaming = false;
    chatState.preparation = ""; chatState.preparationReady = false; chatState.preparationFailed = false;
    renderComposerState();
    renderScopePicker();

    els.messages.textContent = "";
    chatState.streamNode = null;
    chatState.streamReasoning = null;
    chatState.streamText = "";

    // 历史消息随 active 一起推送（library 里只有计数，不带正文）
    for (const message of state.active?.messages ?? []) {
      appendMessage(message.role, message.text, {
        roleLabel: message.role === "user" ? "我" : settingsState.settings?.model ?? "助手",
      });
    }
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
      if (payload.settings) settingsState.settings = payload.settings;
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

  function send() {
    const question = els.input.value.trim();
    if (!question || chatState.streaming) return;

    appendMessage("user", question, { roleLabel: "我" });
    els.input.value = "";
    autoGrow();
    startStreaming();

    invoke("ask", { question, scope: chatState.scope });
  }

  els.sendBtn.addEventListener("click", send);
  els.cancelBtn.addEventListener("click", () => invoke("cancelAnswer"));
  els.scopePicker.addEventListener("change", () => {
    if (!state.active?.scope) chatState.scope = els.scopePicker.value;
    renderScopePicker();
  });
  els.prepRetry.addEventListener("click", () => {
    const dialog = document.getElementById("prepare-confirm");
    document.getElementById("prepare-destination").textContent = `将整本书正文发送至 ${settingsState.settings?.baseURL ?? "当前接口"}，使用 ${settingsState.settings?.model ?? "当前模型"} 生成摘要，会产生 API 用量。摘要保存在本机，可随时清除。不会更改本对话的读取权限。`;
    dialog.showModal();
  });
  document.getElementById("prepare-yes").addEventListener("click", () => {
    document.getElementById("prepare-confirm").close(); invoke("reprocessBook", { confirmed: true });
  });
  document.getElementById("prepare-no").addEventListener("click", () => document.getElementById("prepare-confirm").close());
  document.getElementById("prep-cancel").addEventListener("click", () => invoke("cancelPreparation"));
  document.getElementById("prep-clear").addEventListener("click", () => invoke("clearKnowledge"));
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
    // Enter 发送，Shift+Enter 换行
    if (event.key === "Enter" && !event.shiftKey && !event.isComposing) {
      event.preventDefault();
      send();
    }
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
    els.setScope, els.setMaxTokens, els.setApiKey, els.setThinking,
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

  window.addEventListener("keydown", (event) => {
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
