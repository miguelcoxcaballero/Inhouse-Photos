<script lang="ts">
  import { BasicModal } from '@immich/ui';
  import { locale } from '$lib/stores/preferences.store';
  import { t } from 'svelte-i18n';
  interface Props {
    onClose: () => void;
  }
  let { onClose }: Props = $props();
  const downloadsUrl = 'https://fotos.miguelcoxcaballero.com/descargas/';
  const spanish = $derived($locale?.startsWith('es'));
</script>

<BasicModal title={$t('app_download_links')} size="small" {onClose}>
  <div class="space-y-5 px-2 pb-3 text-sm">
    <div>
      <h2 class="font-semibold">Inhouse Photos · Android</h2>
      <p class="mt-1 text-gray-600 dark:text-gray-300">
        {spanish
          ? 'Descarga la aplicación de Inhouse Photos para Android desde nuestra página.'
          : 'Download the Inhouse Photos Android app from our download page.'}
      </p>
      <a class="mt-2 inline-block font-semibold text-primary underline" href={downloadsUrl} target="_blank" rel="noreferrer">
        {spanish ? 'Abrir descargas' : 'Open downloads'}
      </a>
    </div>
    <div class="border-t border-gray-200 pt-4 dark:border-gray-700">
      <h2 class="font-semibold">Inhouse Photos · iPhone</h2>
      <p class="mt-1 text-gray-600 dark:text-gray-300">
        {spanish
          ? 'Abre esta biblioteca en Safari y usa Compartir → Añadir a pantalla de inicio. La web de iOS no puede hacer copias automáticas continuas en segundo plano.'
          : 'Open this library in Safari and choose Share → Add to Home Screen. The iOS web app cannot perform continuous automatic background backup.'}
      </p>
    </div>
  </div>
</BasicModal>
