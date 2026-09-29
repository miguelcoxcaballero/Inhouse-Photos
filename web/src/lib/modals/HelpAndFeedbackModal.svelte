<script lang="ts">
  import { Icon, Modal, ModalBody } from '@immich/ui';
  import { mdiBugOutline, mdiGithub, mdiInformationOutline } from '@mdi/js';
  import { t } from 'svelte-i18n';

  interface Props {
    onClose: () => void;
  }

  let { onClose }: Props = $props();
</script>

{#snippet link(url: string, icon: string, text: string)}
  <div>
    <a href={url} target="_blank" rel="noreferrer">
      <Icon {icon} size="1.5em" class="inline-block" />
      <p class="inline-block text-sm font-medium text-primary underline">
        {text}
      </p>
    </a>
  </div>
{/snippet}

<Modal title={$t('support_and_feedback')} {onClose} size="small">
  <ModalBody>
    <p>Inhouse Photos</p>
    <div class="mt-5 flex flex-col gap-2">
      {@render link('https://fotos.miguelcoxcaballero.com/descargas/', mdiInformationOutline, $t('documentation'))}
      {@render link('https://github.com/miguelcoxcaballero/Inhouse-Photos', mdiGithub, $t('source'))}
      {@render link('https://github.com/miguelcoxcaballero/Inhouse-Photos/issues', mdiBugOutline, $t('bugs_and_feature_requests'))}
    </div>
  </ModalBody>
</Modal>
