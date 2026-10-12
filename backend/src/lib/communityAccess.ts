/** Only the feed and one harness (with its social state or cover) are public. Mutations and following inventory stay authenticated. */
export function isPublicCommunityRead(method: string, url: string): boolean {
  return method === 'GET' && /^\/api\/community\/harnesses(?:\/[a-z0-9-]{1,80}(?:\/(?:social|cover))?)?$/.test(url.split('?')[0])
}

/**
 * The website's own examples, in the order the Hub draws them (website `starters.ts`, which
 * `contract.spec.ts` checks): a popular feed ranks them among publications, and keeps this order
 * among equals.
 */
export const communityStarters = new Set([
  'starter-ribbon-lamp', 'starter-signal-study', 'starter-alpine-drift', 'starter-two-futures', 'starter-molecular-shapes', 'starter-lantern-room', 'starter-portable-light',
  'starter-harness-keynote',
  'starter-pocket-film', 'starter-moonlight', 'starter-sales-story', 'starter-pleat',
  'starter-sunday', 'starter-orbit', 'starter-blue-hour', 'starter-field-notes', 'starter-make-space',
])

/** Who the starters are by, on the website's cards and to a follower. */
export const communityStarterAuthor = 'harness'
