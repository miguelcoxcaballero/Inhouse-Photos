<script lang="ts">
  interface Props {
    compact?: boolean;
    class?: string;
  }

  let { compact = false, class: className = '' }: Props = $props();
</script>

<span class="inhouse-brand {className}" aria-label="Inhouse Photos">
  <img src="/inhouse-photos-mark.svg" alt="" />
  {#if !compact}
    <span>inhouse photos</span>
  {/if}
</span>

<style>
  .inhouse-brand {
    display: inline-flex;
    align-items: center;
    gap: 0.58rem;
    color: rgb(var(--immich-primary));
    font-size: 1.32rem;
    font-weight: 560;
    letter-spacing: -0.035em;
    line-height: 1;
    white-space: nowrap;
  }

  img {
    width: 2.35rem;
    height: 2.35rem;
    flex: none;
  }
</style>
