import type { ColumnHandle, RepoView } from './types';

// Small set of known GitHub view icon names. Anything unmapped falls back
// to a neutral circle rather than guessing.
const ICON_GLYPHS: Record<string, string> = {
  rocket: '🚀',
  label: '🏷️',
  bug: '🐛',
  star: '⭐',
  milestone: '🏁',
  flame: '🔥',
  checklist: '✅',
  eye: '👀',
  alert: '⚠️',
  clock: '🕐',
};

function applyIcon(el: HTMLElement, iconName: string): void {
  const glyph = ICON_GLYPHS[iconName];
  if (glyph) {
    el.textContent = glyph;
    el.classList.remove('kanban-column__icon--fallback');
  } else {
    el.textContent = '';
    el.classList.add('kanban-column__icon--fallback');
  }
}

export function createColumn(view: RepoView): ColumnHandle {
  const root = document.createElement('div');
  root.className = 'kanban-column';

  const bar = document.createElement('div');
  bar.className = 'kanban-column__bar';
  bar.style.backgroundColor = view.color;
  root.appendChild(bar);

  const header = document.createElement('div');
  header.className = 'kanban-column__header';
  root.appendChild(header);

  const icon = document.createElement('span');
  icon.className = 'kanban-column__icon';
  icon.setAttribute('aria-hidden', 'true');
  applyIcon(icon, view.icon);
  header.appendChild(icon);

  const name = document.createElement('span');
  name.className = 'kanban-column__name';
  name.textContent = view.name;
  header.appendChild(name);

  const count = document.createElement('span');
  count.className = 'kanban-column__count';
  count.textContent = '0';
  header.appendChild(count);

  const dot = document.createElement('span');
  dot.className = 'kanban-column__dot';
  dot.setAttribute('aria-hidden', 'true');
  header.appendChild(dot);

  let list = document.createElement('div');
  list.className = 'kanban-column__list';
  root.appendChild(list);

  function swapList(next: HTMLElement): void {
    list.replaceWith(next);
    list = next;
  }

  function setLoading(): void {
    const next = document.createElement('div');
    next.className = 'kanban-column__list';
    for (let i = 0; i < 3; i += 1) {
      const skeleton = document.createElement('div');
      skeleton.className = 'kanban-column__skeleton';
      next.appendChild(skeleton);
    }
    swapList(next);
  }

  function setIssues(cards: HTMLElement[], totalCount: number): void {
    const next = document.createElement('div');
    next.className = 'kanban-column__list';
    if (cards.length === 0) {
      const empty = document.createElement('div');
      empty.className = 'kanban-column__empty';
      empty.textContent = 'No issues';
      next.appendChild(empty);
    } else {
      for (const card of cards) next.appendChild(card);
    }
    swapList(next);
    count.textContent = String(totalCount);
  }

  function setError(message: string, onRetry: () => void): void {
    const next = document.createElement('div');
    next.className = 'kanban-column__list';

    const error = document.createElement('div');
    error.className = 'kanban-column__error';

    const title = document.createElement('p');
    title.className = 'kanban-column__error-title';
    title.textContent = 'Failed to load';
    error.appendChild(title);

    const detail = document.createElement('p');
    detail.className = 'kanban-column__error-detail';
    detail.textContent = message;
    error.appendChild(detail);

    const retry = document.createElement('button');
    retry.type = 'button';
    retry.className = 'kanban-column__retry';
    retry.textContent = 'Retry';
    retry.addEventListener('click', () => onRetry());
    error.appendChild(retry);

    next.appendChild(error);
    swapList(next);
  }

  function setPulsing(on: boolean): void {
    dot.classList.toggle('is-pulsing', on);
  }

  return { root, setLoading, setIssues, setError, setPulsing };
}
