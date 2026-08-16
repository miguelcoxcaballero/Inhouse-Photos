<script lang="ts">
  import { page } from '$app/state';
  import { Route } from '$lib/route';
  import { featureFlagsManager } from '$lib/managers/feature-flags-manager.svelte';
  import { sidebarStore } from '$lib/stores/sidebar.svelte';
  import { openFileUploadDialog } from '$lib/utils/file-uploader';
  import { Icon } from '@immich/ui';
  import {
    mdiCloudUploadOutline,
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

<nav class="mobile-glass-nav" class:drawer-open={sidebarStore.isOpen} aria-label={$t('primary')}>
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

  <button
    type="button"
    class="backup-action"
    aria-label="Backup local photos and videos"
    onclick={() => void openFileUploadDialog({ mediaOnly: true })}
  >
    <span class="backup-icon"><Icon icon={mdiCloudUploadOutline} size="21" /></span>
    <span>{$t('backup')}</span>
  </button>

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
    right: 0.75rem;
    bottom: calc(0.35rem + env(safe-area-inset-bottom));
    left: 0.75rem;
    display: none;
    min-height: 3.75rem;
    grid-auto-flow: column;
    grid-auto-columns: minmax(0, 1fr);
    align-items: center;
    overflow: hidden;
    padding: 0.25rem;
    border: 1px solid rgb(255 255 255 / 48%);
    border-radius: 1.35rem;
    background: linear-gradient(180deg, rgb(255 255 255 / 22%), transparent 55%), rgb(250 248 245 / 78%);
    box-shadow:
      0 10px 32px rgb(20 10 5 / 16%),
      inset 0 1px 0 rgb(255 255 255 / 58%),
      inset 0 -1px 0 rgb(255 255 255 / 12%);
    -webkit-backdrop-filter: saturate(165%) blur(30px);
    backdrop-filter: saturate(165%) blur(30px);
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
    min-height: 3.2rem;
    flex-direction: column;
    align-items: center;
    justify-content: center;
    gap: 0.08rem;
    border: 0;
    border-radius: 1.05rem;
    background: transparent;
    color: color-mix(in srgb, rgb(var(--immich-fg)) 72%, transparent);
    font: inherit;
    font-size: 0.64rem;
    font-weight: 560;
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

  :global(.dark) .mobile-glass-nav {
    border-color: rgb(255 255 255 / 15%);
    background: linear-gradient(180deg, rgb(255 255 255 / 9%), transparent 55%), rgb(27 21 17 / 82%);
    box-shadow:
      0 12px 36px rgb(0 0 0 / 32%),
      inset 0 1px 0 rgb(255 255 255 / 16%);
  }

  a:active,
  button:active {
    transform: scale(0.94);
  }

  .active {
    background: color-mix(in srgb, rgb(var(--immich-primary)) 14%, transparent);
    color: rgb(var(--immich-primary));
  }

  .backup-action {
    color: rgb(var(--immich-primary));
  }

  .backup-icon {
    display: grid;
    width: 2rem;
    height: 2rem;
    place-items: center;
    margin-top: -0.2rem;
    border-radius: 0.72rem;
    background: rgb(var(--immich-primary));
    color: white;
    box-shadow: 0 5px 14px rgb(var(--immich-primary) / 28%);
  }

  @media (max-width: 767px) {
    .mobile-glass-nav {
      display: grid;
    }

    .mobile-glass-nav.drawer-open {
      transform: translateY(calc(120% + env(safe-area-inset-bottom)));
      opacity: 0;
      pointer-events: none;
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
