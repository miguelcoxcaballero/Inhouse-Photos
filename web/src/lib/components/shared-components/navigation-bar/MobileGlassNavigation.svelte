<script lang="ts">
  import { page } from '$app/state';
  import { Route } from '$lib/route';
  import { featureFlagsManager } from '$lib/managers/feature-flags-manager.svelte';
  import { sidebarStore } from '$lib/stores/sidebar.svelte';
  import { Icon } from '@immich/ui';
  import {
    mdiImageAlbum,
    mdiImageMultiple,
    mdiImageMultipleOutline,
    mdiMagnify,
    mdiViewGridOutline,
  } from '@mdi/js';
  import { t } from 'svelte-i18n';

  const isPhotos = $derived(page.url.pathname === Route.photos() || page.url.pathname.startsWith('/photos/'));
  const isSearch = $derived(page.url.pathname.startsWith(Route.search()));
  const isAlbums = $derived(page.url.pathname.startsWith(Route.albums()));
</script>

<nav class="mobile-glass-nav" aria-label={$t('primary')}>
  <a class:active={isPhotos} href={Route.photos()} data-sveltekit-preload-data="hover">
    <Icon icon={isPhotos ? mdiImageMultiple : mdiImageMultipleOutline} size="24" />
    <span>{$t('photos')}</span>
  </a>

  {#if featureFlagsManager.value.search}
    <a class:active={isSearch} href={Route.search()} data-sveltekit-preload-data="hover">
      <Icon icon={mdiMagnify} size="24" />
      <span>{$t('search')}</span>
    </a>
  {/if}

  <a class:active={isAlbums} href={Route.albums()} data-sveltekit-preload-data="hover">
    <Icon icon={mdiImageAlbum} size="24" />
    <span>{$t('albums')}</span>
  </a>

  <button type="button" class:active={sidebarStore.isOpen} onclick={() => sidebarStore.toggle()}>
    <Icon icon={mdiViewGridOutline} size="24" />
    <span>{$t('library')}</span>
  </button>
</nav>

<style>
  .mobile-glass-nav {
    position: fixed;
    z-index: 40;
    right: 0.65rem;
    bottom: calc(0.55rem + env(safe-area-inset-bottom));
    left: 0.65rem;
    display: none;
    min-height: 4.25rem;
    grid-template-columns: repeat(4, minmax(0, 1fr));
    align-items: center;
    overflow: hidden;
    padding: 0.32rem 0.25rem;
    border: 1px solid color-mix(in srgb, white 42%, transparent);
    border-radius: 1.65rem;
    background:
      linear-gradient(180deg, color-mix(in srgb, white 25%, transparent), transparent 48%),
      color-mix(in srgb, rgb(var(--immich-bg)) 66%, transparent);
    box-shadow:
      0 12px 36px rgb(20 10 5 / 20%),
      inset 0 1px 0 rgb(255 255 255 / 52%),
      inset 0 -1px 0 rgb(255 255 255 / 12%);
    -webkit-backdrop-filter: saturate(185%) blur(24px);
    backdrop-filter: saturate(185%) blur(24px);
    isolation: isolate;
  }

  .mobile-glass-nav::before {
    position: absolute;
    z-index: -1;
    inset: 0;
    border-radius: inherit;
    background: radial-gradient(90% 55% at 50% 0%, rgb(255 255 255 / 24%), transparent 70%);
    content: '';
    pointer-events: none;
  }

  a,
  button {
    position: relative;
    display: flex;
    min-width: 0;
    min-height: 3.55rem;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 0.15rem;
    border: 0;
    border-radius: 1.28rem;
    background: transparent;
    color: color-mix(in srgb, rgb(var(--immich-fg)) 72%, transparent);
    font: inherit;
    font-size: 0.69rem;
    font-weight: 520;
    letter-spacing: -0.01em;
    transition:
      color 180ms ease,
      transform 180ms cubic-bezier(0.2, 0.8, 0.2, 1),
      background-color 180ms ease;
    -webkit-tap-highlight-color: transparent;
  }

  :global(.dark) a,
  :global(.dark) button {
    color: rgb(var(--immich-dark-fg) / 72%);
  }

  a:active,
  button:active {
    transform: scale(0.94);
  }

  .active {
    background: color-mix(in srgb, rgb(var(--immich-primary)) 18%, transparent);
    color: rgb(var(--immich-primary));
  }

  @media (max-width: 767px) {
    .mobile-glass-nav {
      display: grid;
    }
  }

  @media (prefers-reduced-transparency: reduce) {
    .mobile-glass-nav {
      background: rgb(var(--immich-bg));
      -webkit-backdrop-filter: none;
      backdrop-filter: none;
    }

    :global(.dark) .mobile-glass-nav {
      background: rgb(var(--immich-dark-bg));
    }
  }

  @media (prefers-reduced-motion: reduce) {
    a,
    button {
      transition: none;
    }
  }
</style>
