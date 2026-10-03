(() => {
  'use strict';
  const endpoint = '/inhouse-manager/v1/usb';
  const panel = document.querySelector('.connection');
  const elements = Object.fromEntries(['usb-label', 'usb-title', 'usb-message', 'usb-action', 'usb-network', 'retry', 'signin', 'upgrade', 'freshness'].map(id => [id, document.getElementById(id)]));
  let timer, active, busy = false, lastState, lastTitle, sequence = 0;
  const labels = {checking: 'Comprobando USB', no_device: 'Sin móvil conectado', ready: 'Red USB disponible', driver_issue: 'Revisar conexión', detection_unavailable: 'Detección no disponible', connected_needs_network: 'Móvil conectado', connected_needs_unlock: 'Móvil conectado', network_unprepared: 'Móvil conectado', multiple_devices: 'Varios móviles conectados'};
  function text(id, value) { elements[id].textContent = value || ''; }
  function render(state, title, message, action, network = '') {
    const changed = state !== lastState || title !== lastTitle;
    lastState = state; lastTitle = title;
    panel.dataset.state = state;
    text('usb-label', labels[state] || (state === 'login' ? 'Sesión necesaria' : state === 'unavailable' ? 'Gestor no disponible' : 'Conexión USB'));
    text('usb-title', title); text('usb-message', message); text('usb-action', action); text('usb-network', network);
    elements['usb-action'].hidden = !action; elements['usb-network'].hidden = !network;
    if (changed && !window.matchMedia('(prefers-reduced-motion: reduce)').matches) {
      panel.classList.remove('state-changed');
      requestAnimationFrame(() => panel.classList.add('state-changed'));
    }
  }
  async function refresh() {
    if (busy || document.hidden) return;
    clearTimeout(timer); busy = true;
    const requestId = ++sequence, controller = new AbortController(); active = controller;
    const timeout = setTimeout(() => controller.abort(), 8000);
    let inspectionTime = null;
    elements.retry.disabled = true;
    try {
      const response = await fetch(endpoint, {credentials: 'same-origin', cache: 'no-store', redirect: 'error', signal: controller.signal, headers: {Accept: 'application/json'}});
      if (requestId !== sequence) return;
      elements.signin.hidden = true; elements.upgrade.hidden = true;
      if (response.status === 401) {
        render('login', 'Inicia sesión para ver el PC', 'Este estado pertenece al ordenador del servidor. Solo su administrador puede consultarlo.', 'Usa tu cuenta habitual; esta página no pide ni guarda contraseñas.');
        elements.signin.hidden = false;
      } else if (response.status === 404) {
        render('unavailable', 'Actualiza el gestor de Windows', 'Esta instalación todavía no ofrece la detección USB en directo.', 'Instala la versión publicada del gestor y mantenlo abierto en el PC. La biblioteca seguirá en su sitio.');
        elements.upgrade.hidden = false;
      } else if (!response.ok) {
        throw new Error('manager_unavailable');
      } else {
        const status = await response.json();
        if (requestId !== sequence || document.hidden) return;
        if (!status || !Object.hasOwn(labels, status.State) || typeof status.Connected !== 'boolean' || typeof status.Title !== 'string' || typeof status.NetworkReady !== 'boolean' || typeof status.NeedsPreparation !== 'boolean' || typeof status.CanPrepare !== 'boolean' || (status.State === 'ready' && (!status.Connected || !status.NetworkReady))) throw new Error('invalid_status');
        const checkedAt = Date.parse(status.CheckedUtc);
        const age = typeof status.AgeSeconds === 'number' ? status.AgeSeconds * 1000 : Date.now() - checkedAt;
        if (!Number.isFinite(checkedAt) || !Number.isFinite(age) || age > 30000) throw new Error('stale_status');
        inspectionTime = checkedAt;
        const action = status.NeedsPreparation && status.CanPrepare ? 'En el programa de Windows, pulsa «Preparar red USB» y acepta el permiso de Windows.' : ['Volver a comprobar', 'Preparar conexión USB'].includes(status.Action) ? '' : status.Action;
        render(status.State, status.Title, status.Message, action, status.NetworkReady ? 'Red USB disponible' + (status.LinkMbps > 0 ? ' · enlace de ' + status.LinkMbps + ' Mbps' : '') + '. La velocidad real se muestra en los detalles de la copia del móvil.' : '');
      }
      text('freshness', (inspectionTime === null ? 'Consulta a las ' : 'En directo · detectado a las ') + new Date(inspectionTime === null ? Date.now() : inspectionTime).toLocaleTimeString('es', {hour: '2-digit', minute: '2-digit', second: '2-digit'}));
    } catch (error) {
      if (requestId !== sequence || document.hidden) return;
      elements.signin.hidden = true; elements.upgrade.hidden = true;
      render('unavailable', 'No puedo consultar el PC ahora', navigator.onLine ? 'Comprueba que el gestor de Inhouse Photos esté abierto en el ordenador del servidor.' : 'No hay conexión a Internet. Se volverá a comprobar al recuperar la conexión.', 'No significa que hayas desconectado el cable. El estado USB no se puede verificar ahora.');
      text('freshness', 'Reconectando automáticamente…');
    } finally {
      clearTimeout(timeout);
      if (requestId === sequence) { busy = false; active = null; elements.retry.disabled = false; if (!document.hidden) timer = setTimeout(refresh, lastState === 'ready' || lastState === 'no_device' || lastState?.startsWith('connected') ? 2000 : 5000); }
    }
  }
  elements.retry.addEventListener('click', refresh);
  document.addEventListener('visibilitychange', () => { clearTimeout(timer); if (document.hidden) active?.abort(); else refresh(); });
  window.addEventListener('online', refresh);
  refresh();
})();
