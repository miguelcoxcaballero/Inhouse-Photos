<script lang="ts">
  import InhouseBrand from '$lib/components/shared-components/InhouseBrand.svelte';
  import { Card, CardBody, CardHeader, Heading, VStack } from '@immich/ui';
  import type { Snippet } from 'svelte';
  interface Props {
    title?: string;
    children?: Snippet;
    withHeader?: boolean;
    withBackdrop?: boolean;
  }

  let { title, children, withHeader = true, withBackdrop = true }: Props = $props();
</script>

<section class="inhouse-auth relative isolate flex min-h-dvh min-w-dvw items-center justify-center">
  {#if withBackdrop}
    <div class="inhouse-auth-backdrop absolute -z-10 size-full" aria-hidden="true"></div>
  {/if}

  <Card color="secondary" class="inhouse-auth-card m-4 w-full max-w-xl border">
    {#if withHeader}
      <CardHeader class="mt-6">
        <VStack>
          <InhouseBrand class="auth-brand" />
          <Heading size="large" class="font-semibold" color="primary" tag="h1">{title}</Heading>
        </VStack>
      </CardHeader>
    {/if}

    <CardBody class="p-8">
      {@render children?.()}
    </CardBody>
  </Card>
</section>

<style>
  .inhouse-auth {
    padding: max(1rem, env(safe-area-inset-top)) max(1rem, env(safe-area-inset-right))
      max(1rem, env(safe-area-inset-bottom)) max(1rem, env(safe-area-inset-left));
  }

  .inhouse-auth-backdrop {
    background:
      radial-gradient(circle at 18% 12%, rgb(217 119 54 / 24%), transparent 32rem),
      radial-gradient(circle at 88% 86%, rgb(217 119 54 / 12%), transparent 28rem),
      rgb(var(--immich-bg));
  }

  :global(.dark) .inhouse-auth-backdrop {
    background:
      radial-gradient(circle at 18% 12%, rgb(217 119 54 / 22%), transparent 32rem),
      radial-gradient(circle at 88% 86%, rgb(217 119 54 / 10%), transparent 28rem),
      rgb(var(--immich-dark-bg));
  }

  :global(.inhouse-auth-card) {
    overflow: hidden;
    border-color: rgb(255 255 255 / 30%) !important;
    border-radius: 2rem !important;
    background: color-mix(in srgb, rgb(var(--immich-bg)) 69%, transparent) !important;
    box-shadow: 0 24px 80px rgb(33 17 8 / 18%), inset 0 1px 0 rgb(255 255 255 / 45%);
    -webkit-backdrop-filter: saturate(180%) blur(30px);
    backdrop-filter: saturate(180%) blur(30px);
  }

  :global(.dark .inhouse-auth-card) {
    background: color-mix(in srgb, rgb(var(--immich-dark-bg)) 67%, transparent) !important;
  }

  :global(.auth-brand) {
    font-size: clamp(1.8rem, 7vw, 2.6rem);
  }

  :global(.auth-brand img) {
    width: clamp(3.25rem, 15vw, 5rem);
    height: clamp(3.25rem, 15vw, 5rem);
  }

  :global(.inhouse-auth-card input) {
    background: color-mix(in srgb, rgb(var(--immich-dark-fg)) 7%, transparent) !important;
  }

  :global(.inhouse-auth-card div:has(> input)) {
    background: color-mix(in srgb, rgb(var(--immich-dark-fg)) 7%, transparent) !important;
    border-color: rgb(255 255 255 / 12%) !important;
  }

  :global(.inhouse-auth-card button[type='submit']) {
    background: rgb(var(--immich-primary)) !important;
    color: white !important;
    box-shadow: 0 9px 24px rgb(217 119 54 / 24%);
  }
</style>
