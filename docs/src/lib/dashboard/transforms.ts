const EXCERPT_LENGTH = 120;

export function toExcerpt(body: string | null): string {
  if (!body) return '';

  const stripped = body
    .replace(/<[^>]+>/g, ' ')
    .replace(/[#*_`[\]()]/g, '')
    .replace(/\s+/g, ' ')
    .trim();

  if (stripped.length <= EXCERPT_LENGTH) return stripped;

  return `${stripped.slice(0, EXCERPT_LENGTH)}…`;
}
