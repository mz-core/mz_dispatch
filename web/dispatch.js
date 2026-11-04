(function () {
  'use strict';

  const root = document.getElementById('app');
  const panel = document.getElementById('dispatch');
  const list = document.getElementById('call-list');
  const statusMessage = document.getElementById('status-message');
  const connection = document.getElementById('connection');
  const title = document.getElementById('queue-title');
  const kicker = document.getElementById('service-kicker');
  const count = document.getElementById('queue-count');
  const pageLabel = document.getElementById('page-label');
  const categoryFilter = document.getElementById('category-filter');
  const priorityFilter = document.getElementById('priority-filter');
  const statusFilter = document.getElementById('status-filter');
  const searchInput = document.getElementById('search');
  const toast = document.getElementById('toast');
  const panicButton = document.querySelector('[data-action="panic"]');
  const state = {
    serviceCode: '',
    services: {},
    incidentTypes: {},
    priorities: {},
    calls: [],
    page: 1,
    pageSize: 25,
    total: 0,
    errorTimer: 0,
    toastTimer: 0
  };

  function translateError(code) {
    const messages = {
      duty_required: 'Entre em serviço para acessar esta fila.',
      capability_denied: 'Seu cargo não tem acesso a esta fila.',
      organization_not_found: 'Esta organização não está disponível para sua unidade.',
      character_not_active: 'Ative seu personagem para continuar.',
      dispatch_unavailable: 'A central está temporariamente indisponível.',
      dispatch_disabled: 'A central está desativada.',
      invalid_status_filter: 'O filtro de estado não é válido.',
      invalid_category_filter: 'A categoria selecionada não é válida.',
      invalid_priority_filter: 'A prioridade selecionada não é válida.',
      rate_limited: 'Aguarde antes de tentar novamente.'
    };
    return messages[code] || 'Não foi possível concluir a solicitação. Tente novamente.';
  }

  function post(action, payload) {
    if (typeof GetParentResourceName !== 'function') {
      showStatus('Pré-visualização sem conexão com o servidor FiveM.', 'error');
      return Promise.resolve({ ok: false, code: 'nui_unavailable' });
    }
    return fetch(`https://${GetParentResourceName()}/${action}`, {
      method: 'POST',
      headers: { 'Content-Type': 'application/json; charset=UTF-8' },
      body: JSON.stringify(payload || {})
    }).then((response) => response.json()).catch(() => {
      showStatus('Conexão com a central interrompida.', 'error');
      return { ok: false, code: 'nui_transport_failed' };
    });
  }

  function showStatus(message, mode) {
    statusMessage.textContent = message;
    statusMessage.dataset.state = mode || '';
    statusMessage.hidden = false;
    if (mode === 'error') {
      window.clearTimeout(state.errorTimer);
      state.errorTimer = window.setTimeout(() => {
        if (state.calls.length > 0) statusMessage.hidden = true;
      }, 5200);
    }
  }

  function showToast(message) {
    toast.textContent = message;
    toast.hidden = false;
    window.clearTimeout(state.toastTimer);
    state.toastTimer = window.setTimeout(() => { toast.hidden = true; }, 3400);
  }

  function open(services, incidentTypes, priorities) {
    if (services) state.services = services;
    if (incidentTypes) state.incidentTypes = incidentTypes;
    if (priorities) state.priorities = priorities;
    panel.hidden = false;
    root.setAttribute('aria-hidden', 'false');
    connection.textContent = state.serviceCode ? 'Fila conectada' : 'Selecione um serviço';
    if (state.serviceCode) requestAnimationFrame(() => document.getElementById('search').focus());
  }

  function close() {
    panel.hidden = true;
    root.setAttribute('aria-hidden', 'true');
    list.replaceChildren();
    state.calls = [];
    searchInput.value = '';
    post('close');
  }

  function renderCategories() {
    const prior = categoryFilter.value;
    categoryFilter.replaceChildren(new Option('Todas', ''));
    const incidents = state.incidentTypes[state.serviceCode] || [];
    incidents.forEach((incident) => {
      categoryFilter.add(new Option(`${incident.code.toUpperCase()} · ${incident.label}`, incident.code));
    });
    categoryFilter.value = incidents.some((incident) => incident.code === prior) ? prior : '';
  }

  function textNode(tag, className, text) {
    const node = document.createElement(tag);
    if (className) node.className = className;
    node.textContent = text;
    return node;
  }

  function addAction(container, label, action, call, modifier) {
    const button = textNode('button', `action-button${modifier ? ` ${modifier}` : ''}`, label);
    button.type = 'button';
    button.addEventListener('click', () => {
      if (action === 'waypoint') {
        post('request', { action, payload: { x: Number(call.location_x), y: Number(call.location_y) } });
      } else {
        button.disabled = true;
        post('request', { action, payload: { callId: call.public_id } });
      }
    });
    container.append(button);
  }

  function renderCall(call) {
    const row = document.createElement('article');
    row.className = 'call-row';
    const priority = textNode('span', 'priority-mark', String(call.priority_level || 3));
    priority.dataset.priority = String(call.priority_level || 3);
    priority.setAttribute('aria-label', `Prioridade ${call.priority_level || 3}: ${call.priority_label || 'Normal'}`);

    const content = document.createElement('div');
    content.className = 'call-content';
    const meta = document.createElement('div');
    meta.className = 'call-meta';
    meta.append(
      textNode('span', 'category-label', `${call.category_code ? `${String(call.category_code).toUpperCase()} · ` : ''}${call.category_label || 'Ocorrência'}`),
      textNode('span', '', call.priority_label || 'Normal'),
      textNode('span', '', call.status === 'closed' ? 'Encerrado' : call.status === 'accepted' ? 'Em atendimento' : 'Aguardando'),
      textNode('time', '', call.created_at ? String(call.created_at).slice(11, 16) : '--:--')
    );
    meta.lastChild.dateTime = call.created_at || '';
    content.append(meta, textNode('p', 'call-message', call.message || 'Relato sem descrição.'));

    const units = document.createElement('div');
    units.className = 'call-units';
    const assigned = Math.max(0, Number(call.assigned_units) || 0);
    for (let index = 0; index < Math.min(assigned, 5); index += 1) {
      units.append(textNode('span', 'unit-tag', `Unidade ${String(index + 1).padStart(2, '0')}`));
    }
    if (assigned > 5) units.append(textNode('span', 'unit-tag', `+${assigned - 5}`));
    if (Number(call.report_count) > 1) {
      units.append(textNode('span', 'report-tag', `${call.report_count} relatos agrupados`));
    }
    if (call.location_accuracy === 'approximate') {
      units.append(textNode('span', 'report-tag', 'Localização aproximada'));
    }
    if (units.childElementCount > 0) content.append(units);

    const actions = document.createElement('div');
    actions.className = 'call-actions';
    const hasLocation = Number.isFinite(Number(call.location_x)) && Number.isFinite(Number(call.location_y));
    if (hasLocation) addAction(actions, 'GPS', 'waypoint', call);
    if (call.status !== 'closed') {
      addAction(actions, 'Aceitar', 'accept', call);
      addAction(actions, 'Encerrar', 'close', call, 'action-button--close');
    }
    row.append(priority, content, actions);
    return row;
  }

  function renderCalls() {
    const query = searchInput.value.trim().toLocaleLowerCase('pt-BR');
    const filtered = state.calls.filter((call) => {
      const categoryMatch = !categoryFilter.value || call.category_code === categoryFilter.value;
      const priorityMatch = !priorityFilter.value || Number(call.priority_level) === Number(priorityFilter.value);
      const queryMatch = !query || `${call.message || ''} ${call.category_code || ''} ${call.public_id || ''}`
        .toLocaleLowerCase('pt-BR').includes(query);
      return categoryMatch && priorityMatch && queryMatch;
    });
    list.replaceChildren(...filtered.map(renderCall));
    count.textContent = `${state.total} ${state.total === 1 ? 'chamado' : 'chamados'}`;
    const pages = Math.max(1, Math.ceil(state.total / state.pageSize));
    pageLabel.textContent = state.total
      ? `Página ${state.page} de ${pages}`
      : 'Sem resultados';
    document.getElementById('previous-page').disabled = state.page <= 1;
    document.getElementById('next-page').disabled = state.page >= pages;
    if (!state.calls.length) {
      showStatus(state.serviceCode ? 'Nenhuma ocorrência corresponde a estes filtros.' : 'Escolha um serviço para carregar a fila.');
    } else {
      statusMessage.hidden = true;
    }
  }

  function requestList() {
    if (!state.serviceCode) return;
    showStatus('Carregando ocorrências...', 'loading');
    post('request', {
      action: 'filter',
      payload: {
        status: statusFilter.value,
        categoryCode: categoryFilter.value,
        priorityLevel: priorityFilter.value,
        page: state.page
      }
    });
  }

  function setService(serviceCode) {
    state.serviceCode = serviceCode;
    state.calls = [];
    state.page = 1;
    statusFilter.value = 'active';
    categoryFilter.value = '';
    priorityFilter.value = '';
    document.querySelectorAll('[data-service]').forEach((button) => {
      button.setAttribute('aria-pressed', String(button.dataset.service === serviceCode));
    });
    panicButton.hidden = serviceCode !== 'police';
    panicButton.disabled = true;
    const isMedical = serviceCode === 'medical';
    kicker.textContent = isMedical ? 'Atendimento médico' : 'Serviço policial';
    title.textContent = isMedical ? 'Fila de assistência' : 'Fila policial';
    connection.textContent = 'Verificando autorização';
    renderCategories();
    showStatus('Carregando ocorrências...', 'loading');
    post('request', { action: 'service', payload: { serviceCode } });
  }

  document.querySelectorAll('[data-service]').forEach((button) => {
    button.addEventListener('click', () => setService(button.dataset.service));
  });
  document.querySelectorAll('[data-action="close"]').forEach((button) => button.addEventListener('click', close));
  document.getElementById('filters').addEventListener('submit', (event) => {
    event.preventDefault();
    requestList();
  });
  [categoryFilter, priorityFilter, statusFilter].forEach((filter) => {
    filter.addEventListener('change', requestList);
  });
  searchInput.addEventListener('input', renderCalls);
  document.getElementById('previous-page').addEventListener('click', () => {
    if (state.page <= 1) return;
    state.page -= 1;
    requestList();
  });
  document.getElementById('next-page').addEventListener('click', () => {
    if (state.page * state.pageSize >= state.total) return;
    state.page += 1;
    requestList();
  });

  window.addEventListener('message', (event) => {
    const data = event.data || {};
    if (data.action === 'open') open(data.services, data.incidentTypes, data.priorities);
    else if (data.action === 'close') {
      panel.hidden = true;
      root.setAttribute('aria-hidden', 'true');
    } else if (data.action === 'service') {
      state.serviceCode = data.serviceCode || '';
      connection.textContent = 'Fila conectada';
    } else if (data.action === 'calls') {
      state.serviceCode = data.serviceCode || state.serviceCode;
      state.calls = Array.isArray(data.items) ? data.items : [];
      state.page = Number(data.page) || 1;
      state.pageSize = Number(data.pageSize) || 25;
      state.total = Number(data.total) || 0;
      connection.textContent = 'Fila conectada';
      panicButton.hidden = data.serviceCode !== 'police';
      panicButton.disabled = data.serviceCode !== 'police';
      renderCalls();
    } else if (data.action === 'error') {
      connection.textContent = 'Acesso não confirmado';
      panicButton.disabled = true;
      showStatus(translateError(data.code), 'error');
    } else if (data.action === 'accessRevoked') {
      state.calls = [];
      state.total = 0;
      connection.textContent = 'Acesso revogado';
      panicButton.disabled = true;
      renderCalls();
      showStatus('A autorização foi revogada. A fila não está mais disponível.', 'error');
    }
  });

  document.addEventListener('keydown', (event) => {
    if (event.key === 'Escape' && !panel.hidden) close();
  });
})();
