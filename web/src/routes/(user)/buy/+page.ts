import { redirect } from '@sveltejs/kit';
import { authenticate } from '$lib/utils/auth';
import { Route } from '$lib/route';
import type { PageLoad } from './$types';

export const load = (async ({ url }) => {
  await authenticate(url);
  redirect(302, Route.photos());
}) satisfies PageLoad;
