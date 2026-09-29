<script lang="ts">
  import ServerAboutModal from '$lib/modals/ServerAboutModal.svelte';
  import { userInteraction } from '$lib/stores/user.svelte';
  import { websocketStore } from '$lib/stores/websocket';
  import { semverToName } from '$lib/utils';
  import { requestServerInfo } from '$lib/utils/auth';
  import {
    getAboutInfo,
    getVersionHistory,
    type ServerAboutResponseDto,
    type ServerVersionHistoryResponseDto,
  } from '@immich/sdk';
  import { modalManager } from '@immich/ui';
  import { onMount } from 'svelte';
  import { t } from 'svelte-i18n';

  const { serverVersion, connected } = websocketStore;

  let info: ServerAboutResponseDto | undefined = $state();
  let versions: ServerVersionHistoryResponseDto[] = $state([]);

  onMount(async () => {
    if (userInteraction.aboutInfo && userInteraction.versions && $serverVersion) {
      info = userInteraction.aboutInfo;
      versions = userInteraction.versions;
      return;
    }
    await requestServerInfo();
    [info, versions] = await Promise.all([getAboutInfo(), getVersionHistory()]);
    userInteraction.aboutInfo = info;
    userInteraction.versions = versions;
  });
  let version = $derived($serverVersion ? semverToName($serverVersion) : null);
</script>

<div
  class="flex min-w-52 place-content-center place-items-center justify-between overflow-hidden ps-5 pe-1 text-sm md:flex dark:text-immich-dark-fg"
>
  {#if $connected}
    <div class="flex place-content-center place-items-center gap-2">
      <div class="size-1.75 rounded-full bg-green-500"></div>
      <p class="dark:text-immich-gray">{$t('server_online')}</p>
    </div>
  {:else}
    <div class="flex place-content-center place-items-center gap-2">
      <div class="size-1.75 rounded-full bg-red-500"></div>
      <p class="text-red-500">{$t('server_offline')}</p>
    </div>
  {/if}

  <div class="flex justify-between justify-items-center">
    {#if $connected && version}
      <button
        type="button"
        onclick={() => info && modalManager.show(ServerAboutModal, { versions, info })}
        class="flex place-content-center place-items-center gap-1 dark:text-immich-gray"
      >
        {version}
      </button>
    {:else}
      <p class="text-red-500">{$t('unknown')}</p>
    {/if}
  </div>
</div>
