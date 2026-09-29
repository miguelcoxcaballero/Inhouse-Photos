<script lang="ts">
  import ServerAboutItem from '$lib/components/ServerAboutItem.svelte';
  import { locale } from '$lib/stores/preferences.store';
  import { type ServerAboutResponseDto, type ServerVersionHistoryResponseDto } from '@immich/sdk';
  import { Alert, Label, Modal, ModalBody } from '@immich/ui';
  import { DateTime } from 'luxon';
  import { t } from 'svelte-i18n';

  interface Props {
    onClose: () => void;
    info: ServerAboutResponseDto;
    versions: ServerVersionHistoryResponseDto[];
  }

  let { onClose, info, versions }: Props = $props();
</script>

<Modal title={$t('about')} {onClose}>
  <ModalBody>
    <div class="flex flex-col gap-4 sm:grid sm:grid-cols-2">
      {#if info.sourceRef === 'main' && info.repository === 'immich-app/immich'}
        <Alert color="warning" title={$t('main_branch_warning')} class="col-span-full" size="small" />
      {/if}

      <ServerAboutItem id="inhouse-photos" title="Inhouse Photos server" version={info.version} />
      <ServerAboutItem id="exif" title="ExifTool" version={info.exiftool} />
      <ServerAboutItem id="nodejs" title="Node.js" version={info.nodejs} />
      <ServerAboutItem id="libvips" title="Libvips" version={info.libvips} />
      <ServerAboutItem
        id="imagemagick"
        title="ImageMagick"
        version={info.imagemagick}
        class={(info.imagemagick?.length || 0) > 10 ? 'col-span-2' : ''}
      />
      <ServerAboutItem
        id="ffmpeg"
        title="FFmpeg"
        version={info.ffmpeg}
        class={(info.ffmpeg?.length || 0) > 10 ? 'col-span-2' : ''}
      />

      <ServerAboutItem
        id="repository"
        title={$t('repository')}
        version="miguelcoxcaballero/Inhouse-Photos"
        versionHref="https://github.com/miguelcoxcaballero/Inhouse-Photos"
      />

      <ServerAboutItem
        id="open-source-foundation"
        title="Open-source foundation"
        version="Immich (AGPL-3.0)"
        versionHref="https://github.com/immich-app/immich"
      />

      <div class="col-span-full">
        <Label size="small" color="primary" for="version-history">{$t('version_history')}</Label>
        <ul id="version-history" class="list-none">
          {#each versions.slice(0, 5) as item (item.id)}
            {@const createdAt = DateTime.fromISO(item.createdAt)}
            <li>
              <span
                class="pb-2 text-xs immich-form-label"
                id="version-history"
                title={createdAt.toLocaleString(DateTime.DATETIME_SHORT_WITH_SECONDS, { locale: $locale })}
              >
                {$t('version_history_item', {
                  values: {
                    version: item.version,
                    date: createdAt.toLocaleString(
                      {
                        month: 'short',
                        day: 'numeric',
                        year: 'numeric',
                      },
                      { locale: $locale },
                    ),
                  },
                })}
              </span>
            </li>
          {/each}
        </ul>
      </div>
    </div>
  </ModalBody>
</Modal>
