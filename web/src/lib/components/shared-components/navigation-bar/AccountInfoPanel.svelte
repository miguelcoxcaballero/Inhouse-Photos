<script lang="ts">
  import { page } from '$app/state';
  import { focusTrap } from '$lib/actions/focus-trap';
  import { authManager } from '$lib/managers/auth-manager.svelte';
  import AvatarEditModal from '$lib/modals/AvatarEditModal.svelte';
  import HelpAndFeedbackModal from '$lib/modals/HelpAndFeedbackModal.svelte';
  import { Route } from '$lib/route';
  import { userInteraction } from '$lib/stores/user.svelte';
  import { getAboutInfo, type ServerAboutResponseDto } from '@immich/sdk';
  import { Icon, IconButton, modalManager } from '@immich/ui';
  import { mdiChevronRight, mdiCog, mdiHelpCircleOutline, mdiLogout, mdiPencil, mdiWrench } from '@mdi/js';
  import { onMount } from 'svelte';
  import { t } from 'svelte-i18n';
  import { fade } from 'svelte/transition';
  import UserAvatar from '../UserAvatar.svelte';

  type Props = {
    onClose?: () => void;
  };

  let { onClose }: Props = $props();

  let info: ServerAboutResponseDto | undefined = $state();

  onMount(async () => {
    info = userInteraction.aboutInfo ?? (await getAboutInfo());
  });
</script>

<div
  in:fade={{ duration: 100 }}
  out:fade={{ duration: 100 }}
  id="account-info-panel"
  class="account-sheet"
  use:focusTrap
>
  <div class="account-profile">
    <div class="avatar-wrap">
      <UserAvatar user={authManager.user} size="lg" />
      <div class="avatar-edit">
        <IconButton
          color="primary"
          icon={mdiPencil}
          aria-label={$t('edit_avatar')}
          size="tiny"
          shape="round"
          onclick={async () => {
            onClose?.();
            await modalManager.show(AvatarEditModal);
          }}
        />
      </div>
    </div>
    <div class="identity">
      <p>{authManager.user.name}</p>
      <span>{authManager.user.email}</span>
    </div>
  </div>

  <div class="account-actions">
    <a class="account-row" href={Route.userSettings()} onclick={onClose}>
      <span class="row-icon"><Icon icon={mdiCog} size="20" aria-hidden /></span>
      <span>{$t('account_settings')}</span>
      <Icon icon={mdiChevronRight} size="20" aria-hidden />
    </a>

    {#if authManager.user.isAdmin}
      <a
        class="account-row"
        href={Route.systemSettings()}
        onclick={onClose}
        aria-current={page.url.pathname.includes('/admin') ? 'page' : undefined}
      >
        <span class="row-icon"><Icon icon={mdiWrench} size="20" aria-hidden /></span>
        <span>{$t('administration')}</span>
        <Icon icon={mdiChevronRight} size="20" aria-hidden />
      </a>
    {/if}

    <button
      class="account-row"
      type="button"
      onclick={async () => {
        onClose?.();
        if (info) {
          await modalManager.show(HelpAndFeedbackModal, { info });
        }
      }}
    >
      <span class="row-icon"><Icon icon={mdiHelpCircleOutline} size="20" aria-hidden /></span>
      <span>{$t('support_and_feedback')}</span>
      <Icon icon={mdiChevronRight} size="20" aria-hidden />
    </button>

    <a class="account-row sign-out" href={Route.logout()}>
      <span class="row-icon"><Icon icon={mdiLogout} size="20" aria-hidden /></span>
      <span>{$t('sign_out')}</span>
    </a>
  </div>

  <p class="account-version">Inhouse Photos{info?.version ? ` · v${info.version}` : ''}</p>
</div>

<style>
  .account-sheet {
    position: absolute;
    z-index: 70;
    top: 4.65rem;
    right: 1.25rem;
    width: min(21rem, calc(100vw - 2rem));
    overflow: hidden;
    border: 1px solid rgb(var(--immich-fg) / 9%);
    border-radius: 1.4rem;
    background: rgb(250 248 245 / 88%);
    color: rgb(var(--immich-fg));
    box-shadow: 0 20px 56px rgb(31 17 8 / 22%);
    -webkit-backdrop-filter: saturate(170%) blur(28px);
    backdrop-filter: saturate(170%) blur(28px);
  }

  :global(.dark) .account-sheet {
    border-color: rgb(255 255 255 / 11%);
    background: rgb(28 21 17 / 90%);
    color: rgb(var(--immich-dark-fg));
    box-shadow: 0 22px 64px rgb(0 0 0 / 42%);
  }

  .account-profile {
    display: flex;
    align-items: center;
    gap: 0.9rem;
    padding: 1.15rem 1.1rem 1rem;
  }

  .avatar-wrap {
    position: relative;
    flex: none;
  }

  .avatar-edit {
    position: absolute;
    right: -0.15rem;
    bottom: -0.15rem;
  }

  .identity {
    min-width: 0;
  }

  .identity p {
    overflow: hidden;
    margin: 0;
    font-size: 1rem;
    font-weight: 650;
    letter-spacing: -0.02em;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  .identity span {
    display: block;
    overflow: hidden;
    margin-top: 0.1rem;
    color: rgb(var(--immich-fg) / 58%);
    font-size: 0.78rem;
    text-overflow: ellipsis;
    white-space: nowrap;
  }

  :global(.dark) .identity span {
    color: rgb(var(--immich-dark-fg) / 58%);
  }

  .account-actions {
    border-top: 1px solid rgb(var(--immich-fg) / 8%);
  }

  :global(.dark) .account-actions {
    border-top-color: rgb(var(--immich-dark-fg) / 9%);
  }

  .account-row {
    display: grid;
    width: 100%;
    min-height: 3.25rem;
    grid-template-columns: 2rem 1fr auto;
    align-items: center;
    gap: 0.6rem;
    padding: 0 1rem;
    border: 0;
    border-bottom: 1px solid rgb(var(--immich-fg) / 7%);
    background: transparent;
    color: inherit;
    font: inherit;
    font-size: 0.9rem;
    text-align: left;
    text-decoration: none;
    transition: background-color 140ms ease;
  }

  :global(.dark) .account-row {
    border-bottom-color: rgb(var(--immich-dark-fg) / 8%);
  }

  .account-row:hover,
  .account-row:focus-visible {
    background: rgb(var(--immich-primary) / 10%);
    outline: none;
  }

  .row-icon {
    display: grid;
    width: 2rem;
    height: 2rem;
    place-items: center;
    border-radius: 0.7rem;
    background: rgb(var(--immich-primary) / 12%);
    color: rgb(var(--immich-primary));
  }

  .sign-out {
    grid-template-columns: 2rem 1fr;
    color: #c84537;
  }

  .account-version {
    margin: 0;
    padding: 0.65rem 1rem 0.75rem;
    color: rgb(var(--immich-fg) / 45%);
    font-size: 0.68rem;
    text-align: center;
  }

  :global(.dark) .account-version {
    color: rgb(var(--immich-dark-fg) / 42%);
  }

  @media (max-width: 767px) {
    .account-sheet {
      position: fixed;
      top: calc(var(--navbar-height-md) + 0.45rem);
      right: 0.75rem;
      left: 0.75rem;
      width: auto;
      border-radius: 1.35rem;
    }
  }

  @media (prefers-reduced-transparency: reduce) {
    .account-sheet {
      background: rgb(var(--immich-bg));
      -webkit-backdrop-filter: none;
      backdrop-filter: none;
    }

    :global(.dark) .account-sheet {
      background: rgb(var(--immich-dark-bg));
    }
  }
</style>
