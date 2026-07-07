import type { IssueCard } from './types';

function createLabelChip(label: { name: string; color: string }): HTMLSpanElement {
  const chip = document.createElement('span');
  chip.className = 'label';
  chip.style.background = `#${label.color}22`;
  chip.style.color = `#${label.color}`;
  chip.textContent = label.name;
  return chip;
}

export function createIssueCard(issue: IssueCard): HTMLElement {
  const card = document.createElement('a');
  card.href = issue.htmlUrl;
  card.target = '_blank';
  card.rel = 'noopener noreferrer';
  card.className = 'issue-card';

  const number = document.createElement('span');
  number.className = 'issue-number';
  number.textContent = `#${issue.number}`;
  card.append(number);

  const title = document.createElement('p');
  title.className = 'issue-title';
  title.textContent = issue.title;
  card.append(title);

  if (issue.bodyExcerpt) {
    const excerpt = document.createElement('p');
    excerpt.className = 'issue-excerpt';
    excerpt.textContent = issue.bodyExcerpt;
    card.append(excerpt);
  }

  if (issue.labels.length > 0) {
    const labels = document.createElement('div');
    labels.className = 'issue-labels';

    const sorted = [...issue.labels].sort((a, b) => a.name.length - b.name.length);
    const visible = sorted.slice(0, 3);
    const overflow = sorted.slice(3);

    for (const label of visible) {
      labels.append(createLabelChip(label));
    }

    if (overflow.length > 0) {
      const more = document.createElement('span');
      more.className = 'label label-overflow';
      more.title = overflow.map((label) => label.name).join(', ');
      more.textContent = `+${overflow.length} more`;
      labels.append(more);
    }

    card.append(labels);
  }

  return card;
}
