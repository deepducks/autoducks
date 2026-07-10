<script lang="ts">
  interface Props {
    total: number;
    completed: number;
    size?: number;
    stroke?: number;
  }
  let { total, completed, size = 20, stroke = 4 }: Props = $props();

  const radius = (size - stroke) / 2;
  const circumference = 2 * Math.PI * radius;

  let pct = $derived(total > 0 ? Math.min(1, completed / total) : 0);
  let color = $derived(pct >= 1 ? '#0E8A16' : pct > 0 ? '#FBCA04' : '#8B949E');
  let dash = $derived(`${circumference * pct} ${circumference}`);
</script>

<span class="donut" title={`${completed}/${total} subtasks done`}>
  <svg width={size} height={size} viewBox={`0 0 ${size} ${size}`} aria-hidden="true">
    <circle
      cx={size / 2}
      cy={size / 2}
      r={radius}
      fill="none"
      stroke="var(--sl-color-gray-5)"
      stroke-width={stroke}
    />
    <circle
      cx={size / 2}
      cy={size / 2}
      r={radius}
      fill="none"
      stroke={color}
      stroke-width={stroke}
      stroke-dasharray={dash}
      stroke-linecap="round"
      transform={`rotate(-90 ${size / 2} ${size / 2})`}
    />
  </svg>
  <span class="donut__label">{completed}/{total}</span>
</span>

<style>
  .donut {
    display: inline-flex;
    align-items: center;
    gap: 0.3rem;
    font-variant-numeric: tabular-nums;
    color: var(--sl-color-gray-2);
    cursor: help;
  }
  .donut__label {
    font-size: 0.72rem;
  }
</style>
