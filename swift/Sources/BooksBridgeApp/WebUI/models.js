/* Provider credentials stay in native storage; only replacement values cross the bridge. */
(() => {
  const $ = id => document.getElementById(id);
  const servicePresets = [
    {id:'openai',name:'OpenAI',baseURL:'https://api.openai.com/v1',requiresKey:true,note:'使用 OpenAI 兼容接口；添加后选择需要的模型。'},
    {id:'anthropic',name:'Anthropic',baseURL:'https://api.anthropic.com/v1',requiresKey:true,note:'使用 Anthropic 官方 OpenAI 兼容层，建议手动添加模型；此方式不返回 Claude 思考内容。新模型默认不发送温度参数。'},
    {id:'deepseek',name:'DeepSeek',baseURL:'https://api.deepseek.com/v1',requiresKey:true,note:'填写 DeepSeek API Key 后添加模型；不会自动发起请求。'},
    {id:'openrouter',name:'OpenRouter',baseURL:'https://openrouter.ai/api/v1',requiresKey:true,note:'使用 OpenRouter API Key；模型 ID 通常包含服务商前缀，可通过获取列表添加。'},
    {id:'local',name:'本地',baseURL:'http://localhost:11434/v1',requiresKey:false,note:'默认填写 Ollama 地址。其他本地服务可修改端口和路径，例如 LM Studio 通常使用 http://localhost:1234/v1。'},
    {id:'custom',name:'自定义',baseURL:'',requiresKey:true,note:'填写 OpenAI 兼容服务的名称和 API 基础地址。'},
  ];
  let catalog = null, selection = {}, hooks, currentService = null, dirty = false;
  let modelEdit = null, deleteAction = null, pickerPurpose = 'chat', pickerTarget = null;
  let catalogSignature = '', serial = 0;
  const requests = new Map(), tests = new Map();
  // Discovery belongs to the provider, not to a transient settings DOM subtree.
  const libraries = new Map(), connectionExpanded = new Map();
  let libraryService = null;
  const canonical = value => JSON.stringify(value, function(key, item) {
    return item && !Array.isArray(item) && typeof item === 'object'
      ? Object.fromEntries(Object.keys(item).sort().map(k => [k,item[k]])) : item;
  });
  function library(id) {
    if (!libraries.has(id)) libraries.set(id, {ids:[], selected:new Set(), query:'', onlyNew:false,
      loaded:false, revision:null, loading:false, adding:false, message:'', scroll:0});
    return libraries.get(id);
  }
  const signature = item => item ? `${item.service.revision}:${item.model.revision}` : null;
  const node = (tag, text, cls) => { const el = document.createElement(tag); if (text != null) el.textContent = text; if (cls) el.className = cls; return el; };
  const button = (text, click, cls = 'btn-plain') => { const el = node('button', text, cls); el.type = 'button'; el.onclick = click; return el; };
  function request(action, payload, done) {
    const remote = action === 'testModel' || action === 'listModels';
    if (remote) for (const [id, pending] of requests) {
      if (pending.remote) { requests.delete(id); pending.done?.({success:false,message:'已被新的检测替代'}); }
    }
    const requestID = `model-${++serial}`; requests.set(requestID, { done, remote, action, id:payload.id, serviceID:payload.serviceID,
      configuration: action === 'testModel' ? signature(findModel(payload.id)) : catalog?.services.find(s => s.id === payload.serviceID)?.revision });
    hooks.invoke(action, { ...payload, requestID });
  }
  function findModel(id) {
    for (const service of catalog?.services || []) { const model = service.models.find(m => m.id === id); if (model) return { service, model }; }
    return null;
  }
  function label(id) { const item = findModel(id); return item ? `${item.service.name} / ${item.model.name}${item.service.enabled ? '' : '（已停用）'}` : id ? '模型不可用，请重新选择' : '选择模型'; }
  function ready(service) { return service.enabled && (!service.requiresKey || service.hasKey); }
  function fillSelect(el, selected) {
    el.replaceChildren(); const empty = node('option', '请选择模型'); empty.value = ''; el.append(empty);
    for (const service of catalog?.services || []) {
      const group = document.createElement('optgroup'); group.label = service.name;
      for (const model of service.models) { const option = node('option', model.name); option.value = model.id; option.disabled = !ready(service); group.append(option); }
      el.append(group);
    }
    if (selected && !findModel(selected)) { const unavailable = node('option', '原模型已删除，请重新选择'); unavailable.value = selected; unavailable.disabled = true; el.append(unavailable); }
    el.value = selected || '';
  }
  function defaults() {
    fillSelect($('default-chat-model'), catalog?.defaultChat);
    fillSelect($('default-summary-model'), catalog?.defaultSummary);
  }
  function renderList() {
    $('service-list').replaceChildren();
    for (const service of catalog?.services || []) {
      const el = button(`${service.name}${service.enabled ? '' : ' · 已停用'}`, () => {
        if (dirty) { status('请先保存当前服务商，或点击放弃修改。'); return; }
        currentService = service.id; renderService(); renderList();
      }, 'service-item' + (service.id === currentService ? ' selected' : ''));
      $('service-list').append(el);
    }
  }
  function field(form, title, id, value, type = 'text') {
    const wrap = node('div', null, 'field'), lab = node('label', title), input = document.createElement('input');
    lab.htmlFor = id; input.id = id; input.type = type;
    if (type === 'checkbox') { input.checked = value; wrap.classList.add('field-check'); } else input.value = value ?? '';
    if (type === 'password') input.autocomplete = 'new-password';
    input.oninput = () => { dirty = true; status('有未保存的服务商修改'); };
    wrap.append(lab, input); form.append(wrap); return input;
  }
  function renderService() {
    const host = $('service-detail'); host.replaceChildren();
    const service = catalog?.services.find(s => s.id === currentService);
    if (!service && currentService !== 'new') { host.append(node('p', '添加服务商后，在其下添加模型。', 'field-hint')); return; }
    const form = document.createElement('form');
    if (service) {
      const heading = node('div', null, 'service-heading');
      heading.append(node('h2', service.name), node('span', service.enabled ? '已启用' : '已停用', 'field-hint')); host.append(heading);
      const details = document.createElement('details'); details.className = 'service-connection';
      details.open = connectionExpanded.get(service.id) ?? !ready(service);
      const summary = node('summary', '连接配置'); summary.append(node('span', service.hasKey ? '密钥已保存' : service.requiresKey ? '待配置密钥' : '无需密钥', 'field-hint'));
      details.append(summary, form); host.append(details);
      details.ontoggle = () => connectionExpanded.set(service.id, details.open);
    } else host.append(form);
    if (!service) {
      const wrap = node('div', null, 'field'), label = node('label', '服务商预设'), select = document.createElement('select');
      label.htmlFor = 'service-preset'; select.id = 'service-preset';
      for (const preset of servicePresets) { const option = node('option', preset.name); option.value = preset.id; select.append(option); }
      const note = node('p', '', 'field-hint'); note.id = 'service-preset-hint';
      select.onchange = () => {
        const preset = servicePresets.find(item => item.id === select.value);
        $('service-name').value = preset.id === 'custom' ? '' : preset.name;
        $('service-url').value = preset.baseURL; $('service-requires-key').checked = preset.requiresKey;
        // A credential entered for one destination must not follow a different preset.
        $('service-key').value = ''; $('service-clear-key').checked = false; $('service-key').disabled = false;
        note.textContent = preset.note; dirty = true; status('预设已填入，可修改后保存。');
      };
      wrap.append(label, select, note); form.append(wrap);
    }
    field(form, '服务商名称', 'service-name', service?.name).required = true;
    field(form, 'API 基础地址（含所需路径，例如 /v1）', 'service-url', service?.baseURL, 'url').required = true;
    field(form, '启用服务商', 'service-enabled', service?.enabled ?? true, 'checkbox');
    field(form, '需要 API Key', 'service-requires-key', service?.requiresKey ?? true, 'checkbox');
    const key = field(form, 'API Key', 'service-key', '', 'password');
    key.placeholder = service?.hasKey ? '已保存；留空保持原密钥' : '未配置';
    form.append(node('p', '密钥仅在本机按服务商独立保存（0600 权限），不会回填到界面。', 'field-hint'));
    const clear = field(form, '清除已保存的密钥', 'service-clear-key', false, 'checkbox');
    clear.parentElement.hidden = !service?.hasKey;
    clear.onchange = () => { dirty = true; key.disabled = clear.checked; if (clear.checked) key.value = ''; };
    const actions = node('div', null, 'model-actions');
    const save = node('button', '保存服务商', 'btn-primary'); save.type = 'submit'; actions.append(save);
    actions.append(button('放弃修改', () => { dirty = false; if (currentService === 'new') currentService = catalog.services[0]?.id ?? null; renderService(); renderList(); status(''); }));
    if (service) actions.append(button('删除服务商', () => confirmDelete('该服务商、其模型和密钥将被删除。历史聊天与摘要保留，相关模型选择将失效。', 'deleteService', {id:service.id}), 'btn-plain danger'));
    form.append(actions);
    form.onsubmit = event => {
      event.preventDefault(); save.disabled = true;
      request('saveService', { ...(service ? {id:service.id} : {}), name:$('service-name').value.trim(), baseURL:$('service-url').value.trim(),
        enabled:$('service-enabled').checked, requiresKey:$('service-requires-key').checked,
        ...(clear.checked ? {key:''} : key.value.trim() ? {key:key.value.trim()} : {}) }, result => {
          save.disabled = false;
          if (result.success) { dirty = false; currentService = result.serviceID; key.value = ''; catalogSignature = ''; }
        });
    };
    if (!service) { $('service-preset').onchange(); return; }
    const head = node('div', null, 'model-actions model-list-heading'); head.append(node('h3', '已添加模型'));
    head.append(button('手动添加', () => editModel(service.id)));
    const discover = button('＋ 添加模型', () => openLibrary(service.id), 'btn-primary'); discover.id = 'service-models-add';
    head.append(discover); host.append(head);
    if (!service.models.length) host.append(node('p', '还没有模型。获取列表并勾选添加，或手动填写模型 ID。', 'model-empty'));
    for (const model of service.models) {
      const row = node('div', null, 'service-model-row'); const info = node('div');
      info.append(node('strong', model.name), node('div', `${model.remoteID} · 上下文 ${model.contextTokens.toLocaleString()}`, 'field-hint'));
      const tested = tests.get(model.id); const testState = node('div', tested?.configuration === signature({service,model}) ? tested.message : '未检测', 'field-hint');
      testState.dataset.modelTest = model.id; info.append(testState); row.append(info);
      row.append(button('设置', () => editModel(service.id, model)));
      const test = button('测试连接', () => {
        if (dirty) { status('请先保存服务商修改。'); return; }
        test.disabled = true; status(`正在测试 ${model.name}…`);
        request('testModel', {id:model.id}, result => { test.disabled = false; });
      }); test.disabled = !ready(service); row.append(test);
      row.append(button('删除', () => confirmDelete('删除此模型配置？历史回复与摘要保留，相关模型选择将失效。', 'deleteModel', {serviceID:service.id,id:model.id}), 'btn-plain danger'));
      host.append(row);
    }
  }
  function openLibrary(serviceID) {
    if (dirty) { status('请先保存服务商修改。'); return; }
    libraryService = serviceID;
    const state = library(serviceID);
    $('model-library-search').value = state.query; $('model-library-new').checked = state.onlyNew;
    renderLibrary(); $('model-library').showModal(); $('model-library-rows').scrollTop = state.scroll;
    $('model-library-search').focus();
    // Opening/reopening never fetches. Only the explicit refresh button uses the API.
  }
  function libraryContext() {
    const service = catalog?.services.find(s => s.id === libraryService);
    if (!service) return null;
    const state = library(service.id), added = new Set(service.models.map(m => m.remoteID));
    const available = new Set(state.ids), fresh = state.loaded && state.revision === service.revision;
    const selected = [...state.selected].filter(id => !added.has(id));
    const eligible = selected.filter(id => available.has(id));
    const query = state.query.trim().toLocaleLowerCase();
    const names = new Map(service.models.map(m => [m.remoteID,m.name]));
    const visible = [...new Set([...state.ids,...selected])].filter(id =>
      (!state.onlyNew || !added.has(id)) && `${names.get(id) || ''} ${id}`.toLocaleLowerCase().includes(query));
    return {service,state,added,available,fresh,selected,eligible,visible,names};
  }
  function renderLibrary() {
    const context = libraryContext(); if (!context) { $('model-library').close(); return; }
    const {service,state,added,available,fresh,selected,eligible,visible,names} = context;
    $('model-library-provider').textContent = service.name;
    $('model-library-refresh').textContent = state.loading ? '正在获取…' : state.loaded ? '刷新列表' : '获取列表';
    $('model-library-refresh').disabled = state.loading || state.adding || !ready(service);
    $('model-library-count').textContent = state.loaded ? `${visible.length} / ${state.ids.length} 个模型` : '';
    const stale = state.loaded && !fresh;
    $('model-library-status').textContent = state.message || (!ready(service) ? '请先启用服务商并配置密钥。' : stale ? '连接配置已更改，请刷新列表。已选项仍保留。' : state.loading ? '正在获取列表，已有列表和选择保持不变。' : state.loaded ? '可跨搜索结果选择；关闭窗口后仍保留选择。' : '点击「获取列表」后选择模型；也可返回手动添加。');
    const selectable = visible.filter(id => available.has(id) && !added.has(id));
    const checkedCount = selectable.filter(id => state.selected.has(id)).length;
    const all = $('model-library-all'); all.checked = !!selectable.length && checkedCount === selectable.length;
    all.indeterminate = checkedCount > 0 && checkedCount < selectable.length;
    all.disabled = !selectable.length || state.adding;
    $('model-library-new').disabled = state.adding;
    const host = $('model-library-rows'), scroll = host.scrollTop;
    const focusedID = host.contains(document.activeElement) ? document.activeElement.dataset.remoteId : null;
    host.replaceChildren();
    for (const id of visible) {
      const row = node('label', null, 'library-model-row');
      const checkbox = document.createElement('input'); checkbox.type = 'checkbox'; checkbox.dataset.remoteId = id;
      checkbox.checked = added.has(id) || state.selected.has(id); checkbox.disabled = added.has(id) || state.adding;
      checkbox.onchange = () => { checkbox.checked ? state.selected.add(id) : state.selected.delete(id); state.message = ''; renderLibrary(); };
      const info = node('div', null, 'library-model-info');
      info.append(node('strong', names.get(id) || id.split('/').pop() || id), node('span', id, 'field-hint'));
      row.append(checkbox, info);
      if (added.has(id)) { row.classList.add('is-added'); row.append(node('span', '已添加', 'library-badge')); }
      else if (!available.has(id)) row.append(node('span', '列表中已不可用', 'library-badge'));
      host.append(row);
      if (focusedID === id) checkbox.focus({preventScroll:true});
    }
    if (!visible.length) host.append(node('p', state.loading ? '正在获取模型列表…' : !state.loaded ? '从服务商获取可用模型' : state.query ? '没有匹配的模型，试试其他关键词。' : '没有可添加的模型', 'model-empty'));
    host.scrollTop = scroll;
    const missing = selected.length - eligible.length;
    $('model-library-selected').textContent = `已选择 ${selected.length} 个${missing ? `（${missing} 个已不可用）` : ''}`;
    $('model-library-clear').hidden = !selected.length; $('model-library-clear').disabled = state.adding;
    $('model-library-add').textContent = state.adding ? '正在添加…' : `添加所选（${eligible.length}）`;
    $('model-library-add').disabled = !eligible.length || !fresh || state.loading || state.adding;
  }
  function refreshLibrary() {
    const context = libraryContext(); if (!context || context.state.loading || context.state.adding || !ready(context.service)) return;
    const {service,state} = context, revision = service.revision;
    state.loading = true; state.message = ''; renderLibrary();
    request('listModels', {serviceID:service.id}, result => {
      state.loading = false;
      if (result.success) {
        state.ids = [...new Set((result.models || []).filter(id => typeof id === 'string' && id.trim()).map(id => id.trim()))];
        state.loaded = true; state.revision = revision; state.message = '';
      } else state.message = `${result.message}。已有列表和选择已保留，可重试。`;
      if (libraryService === service.id && $('model-library').open) renderLibrary();
    });
  }
  function addSelectedModels() {
    const context = libraryContext(); if (!context) return;
    const {service,state,eligible,fresh} = context;
    if (!eligible.length || !fresh || state.loading || state.adding) return;
    state.adding = true; state.message = ''; renderLibrary();
    request('addModels', {serviceID:service.id, revision:service.revision, remoteIDs:eligible}, result => {
      state.adding = false; state.message = result.message;
      if (result.success) {
        for (const id of eligible) state.selected.delete(id);
        if (libraryService === service.id && $('model-library').open) $('model-library').close();
      } else if (libraryService === service.id && $('model-library').open) renderLibrary();
    });
  }
  function isAnthropic(serviceID) {
    try { return new URL(catalog?.services.find(s => s.id === serviceID)?.baseURL).hostname === 'api.anthropic.com'; }
    catch { return false; }
  }
  function editModel(serviceID, model = null, remoteID = '') {
    if (dirty) { status('请先保存服务商修改。'); return; }
    modelEdit = {serviceID, ...(model ? {id:model.id} : {})};
    $('model-name').value = model?.name ?? remoteID; $('model-remote').value = model?.remoteID ?? remoteID;
    $('model-context').value = model?.contextTokens ?? 32768; $('model-output').value = model?.outputTokens ?? 2048;
    $('model-temperature').value = model?.temperature ?? 0.3; $('model-send-temp').checked = model?.sendsTemperature ?? !isAnthropic(serviceID);
    $('model-thinking').value = model?.thinking ?? 'off'; $('model-send-thinking').checked = model?.sendsThinking ?? false;
    $('model-form-error').textContent = ''; $('model-form').querySelector('[type=submit]').disabled = false;
    $('model-editor').showModal();
  }
  function confirmDelete(text, action, payload) {
    deleteAction = {action,payload}; $('model-delete-text').textContent = text; $('model-delete-confirm').disabled = false;
    $('model-delete-dialog').showModal();
  }
  function status(text) { $('model-result').textContent = text; }
  function renderPicker() {
    const host = $('model-picker-options'); host.replaceChildren();
    const query = $('model-search').value.toLocaleLowerCase(); let count = 0;
    for (const service of catalog?.services || []) {
      const models = service.models.filter(m => `${service.name} ${m.name} ${m.remoteID}`.toLocaleLowerCase().includes(query));
      if (!models.length) continue;
      host.append(node('h3', service.name));
      for (const model of models) {
        const el = button(model.name + (ready(service) ? '' : ' · 未启用或缺少密钥'), () => {
          request('selectModel', {...pickerTarget, purpose:pickerPurpose,id:model.id}, result => { if (result.success) $('model-picker').close(); else $('model-picker-title').textContent = result.message; });
        }, 'model-picker-option'); el.disabled = !ready(service); host.append(el); count++;
      }
    }
    if (!count) host.append(node('p', '没有可选模型，请先在设置 → 模型服务中添加。', 'field-hint'));
  }
  function openPicker(purpose) {
    const context = hooks.context();
    if (!context.active?.assetID || (purpose === 'chat' && (context.streaming || context.active.archived)) || (purpose === 'summary' && context.summaryRunning)) return;
    pickerTarget = {...context.active}; delete pickerTarget.messages;
    pickerPurpose = purpose; $('model-search').value = ''; $('model-picker-title').textContent = purpose === 'chat' ? '选择对话模型' : '选择全文摘要模型'; renderPicker(); $('model-picker').showModal();
  }
  window.ModelManager = {
    get chatReady() { return catalog ? selection.chatReady === true : undefined; },
    get summaryReady() { return catalog ? selection.summaryReady === true : undefined; },
    get summaryName() { return label(selection.summary); },
    get chatName() { return catalog ? label(selection.chat) : undefined; },
    init(callbacks) {
      hooks = callbacks;
      for (const id of ['model-library-close','model-library-cancel']) $(id).onclick = () => $('model-library').close();
      $('model-library-rows').onscroll = () => { if (libraryService) library(libraryService).scroll = $('model-library-rows').scrollTop; };
      $('model-library-search').oninput = event => { library(libraryService).query = event.target.value; renderLibrary(); $('model-library-rows').scrollTop = 0; };
      $('model-library-new').onchange = event => { library(libraryService).onlyNew = event.target.checked; renderLibrary(); $('model-library-rows').scrollTop = 0; };
      $('model-library-all').onchange = event => {
        const context = libraryContext(); if (!context) return;
        const checked = event.target.checked;
        for (const id of context.visible) if (!context.added.has(id) && context.available.has(id)) {
          checked ? context.state.selected.add(id) : context.state.selected.delete(id);
        }
        renderLibrary();
      };
      $('model-library-clear').onclick = () => { library(libraryService).selected.clear(); renderLibrary(); };
      $('model-library-refresh').onclick = refreshLibrary;
      $('model-library-add').onclick = addSelectedModels;
      $('service-add').onclick = () => { if (dirty) { status('请先保存或放弃当前修改。'); return; } currentService = 'new'; dirty = true; renderService(); renderList(); };
      for (const purpose of ['chat','summary']) $('default-' + purpose + '-model').onchange = event => request('setDefaultModel', {purpose,id:event.target.value});
      $('composer-model').onclick = () => openPicker('chat'); $('summary-model').onclick = () => openPicker('summary');
      $('model-search').oninput = renderPicker; $('model-picker-close').onclick = () => $('model-picker').close();
      $('model-edit-cancel').onclick = () => $('model-editor').close();
      $('model-form').onsubmit = event => {
        event.preventDefault(); const submit = $('model-form').querySelector('[type=submit]'); submit.disabled = true;
        request('saveModel', {...modelEdit, name:$('model-name').value.trim(), remoteID:$('model-remote').value.trim(),
          contextTokens:Number($('model-context').value),outputTokens:Number($('model-output').value),temperature:Number($('model-temperature').value),
          sendsTemperature:$('model-send-temp').checked,sendsThinking:$('model-send-thinking').checked,thinking:$('model-thinking').value}, result => {
            submit.disabled = false; if (result.success) { $('model-editor').close(); catalogSignature = ''; } else $('model-form-error').textContent = result.message;
          });
      };
      $('model-delete-cancel').onclick = () => $('model-delete-dialog').close();
      $('model-delete-confirm').onclick = () => { $('model-delete-confirm').disabled = true; request(deleteAction.action, {...deleteAction.payload,confirmed:true}, result => {
        $('model-delete-confirm').disabled = false; if (result.success) { $('model-delete-dialog').close(); dirty = false; catalogSignature = ''; }
        else $('model-delete-text').textContent = result.message;
      }); };
    },
    receive(payload) {
      if (payload.modelResult) {
        let result = payload.modelResult; const pending = requests.get(result.requestID);
        if (pending) {
          requests.delete(result.requestID);
          if (pending.remote) {
            const current = pending.action === 'testModel' ? signature(findModel(pending.id)) : catalog?.services.find(s => s.id === pending.serviceID)?.revision;
            if (current !== pending.configuration) result = {...result,success:false,models:[],message:'配置已更改，请重新检测。'};
            else if (pending.action === 'testModel') {
              const message = `${result.message} · ${new Date().toLocaleTimeString()}`;
              tests.set(pending.id,{configuration:current,message});
              for (const el of document.querySelectorAll('[data-model-test]')) if (el.dataset.modelTest === pending.id) el.textContent = message;
            }
          }
          status(result.message); hooks.feedback(result.message); pending.done?.(result);
        }
      }
      if (payload.modelSelection) selection = payload.modelSelection;
      if (payload.modelCatalog) {
        catalog = payload.modelCatalog; const signature = canonical(catalog);
        if (signature !== catalogSignature) {
          catalogSignature = signature; defaults();
          for (const id of libraries.keys()) if (!catalog.services.some(s => s.id === id)) libraries.delete(id);
          if (!currentService || (currentService !== 'new' && !catalog.services.some(s => s.id === currentService))) currentService = catalog.services[0]?.id ?? null;
          renderList(); if (!dirty) renderService();
          if (catalog.loadError) status(catalog.loadError);
          if ($('model-picker').open) renderPicker();
          if ($('model-library').open) renderLibrary();
        }
      }
    },
    renderSelection(streaming, running) {
      if (!catalog) return;
      $('composer-model').textContent = label(selection.chat) + ' ▾'; $('composer-model').disabled = streaming || !!hooks?.context().active?.archived;
      $('summary-model').textContent = '摘要模型：' + label(selection.summary) + ' ▾'; $('summary-model').disabled = running;
      $('summary-model-used').textContent = selection.summaryUsed ? `现有摘要：${selection.summaryUsed}` : '';
    },
  };
})();
