<script lang="ts">
  import AppDownloadModal from '$lib/modals/AppDownloadModal.svelte';
  import { Button, HStack, modalManager } from '@immich/ui';
  import { mdiCellphoneArrowDownVariant } from '@mdi/js';
  import { t } from 'svelte-i18n';
</script>

<p>{$t('mobile_app_download_onboarding_note')}</p>

<HStack>
  <Button
    size="medium"
    shape="semi-round"
    fullWidth
    onclick={() => modalManager.show(AppDownloadModal, {})}
    leadingIcon={mdiCellphoneArrowDownVariant}
  >
    {$t('app_stores')}
  </Button>

</HStack>
