/** Modales: error amigable, confirmación e información. */
import { ACTION_LABELS, ErrorAction, ErrorInfo, toErrorInfo } from '../../shared/errors.js';
import { api, UiError } from '../api.js';
import { h } from '../dom.js';

function root(): HTMLElement {
  return document.getElementById('modal-root')!;
}

function openModal(content: HTMLElement): { close: () => void } {
  const back = h('div', { class: 'modal-back', role: 'dialog', 'aria-modal': 'true' }, content);
  root().append(back);
  const close = () => back.remove();
  return { close };
}

/** Normaliza cualquier error a ErrorInfo (y registra los inesperados). */
export function errorInfoOf(err: unknown): ErrorInfo {
  if (err instanceof UiError) return err.info;
  const info = toErrorInfo(err);
  void api().logError(info.details ?? String(err));
  return info;
}

/**
 * Muestra un error con lenguaje simple, acciones sugeridas y detalles plegados.
 * Devuelve la acción elegida por el usuario.
 */
export function showError(err: unknown): Promise<ErrorAction> {
  const info = errorInfoOf(err);
  return new Promise((resolve) => {
    const details = h('div', { class: 'details' }, info.details ?? '');
    const actions = h('div', { class: 'actions' });
    const m = openModal(
      h('div', { class: 'modal' },
        h('h2', null, h('span', { class: 'icon-warn' }, '!'), info.title),
        h('p', null, info.message),
        details,
        actions,
      ),
    );
    const finish = (a: ErrorAction) => { m.close(); resolve(a); };
    actions.append(h('button', { class: 'btn', onclick: () => details.classList.toggle('open') }, 'Ver detalles'));
    for (const a of info.actions) {
      if (a === 'copyReport') {
        const b = h('button', { class: 'btn', onclick: async () => { await api().report(info); b.textContent = 'Copiado ✓'; } }, ACTION_LABELS.copyReport);
        actions.append(b);
      } else if (a === 'openLogs') {
        actions.append(h('button', { class: 'btn', onclick: () => void api().openLogs() }, ACTION_LABELS.openLogs));
      } else if (a !== 'close') {
        actions.append(h('button', { class: 'btn secondary', onclick: () => finish(a) }, ACTION_LABELS[a]));
      }
    }
    if (!info.actions.includes('copyReport')) {
      const b = h('button', { class: 'btn', onclick: async () => { await api().report(info); b.textContent = 'Copiado ✓'; } }, ACTION_LABELS.copyReport);
      actions.append(b);
    }
    actions.append(h('button', { class: 'btn primary', onclick: () => finish('close') }, 'Cerrar'));
  });
}

export function confirmDialog(title: string, message: string, yes = 'Aceptar', no = 'Cancelar'): Promise<boolean> {
  return new Promise((resolve) => {
    const m = openModal(
      h('div', { class: 'modal' },
        h('h2', null, title),
        h('p', null, message),
        h('div', { class: 'actions' },
          h('button', { class: 'btn', onclick: () => { m.close(); resolve(false); } }, no),
          h('button', { class: 'btn primary', onclick: () => { m.close(); resolve(true); } }, yes),
        ),
      ),
    );
  });
}

export function infoDialog(title: string, body: string | HTMLElement): Promise<void> {
  return new Promise((resolve) => {
    const m = openModal(
      h('div', { class: 'modal' },
        h('h2', null, title),
        typeof body === 'string' ? h('p', null, body) : body,
        h('div', { class: 'actions' }, h('button', { class: 'btn primary', onclick: () => { m.close(); resolve(); } }, 'Aceptar')),
      ),
    );
  });
}

/** Modal genérico con contenido propio (p. ej. opciones). */
export function customDialog(content: HTMLElement): { close: () => void } {
  return openModal(h('div', { class: 'modal' }, content));
}
