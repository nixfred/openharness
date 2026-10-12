import { describe, expect, it } from 'vitest';
import { feedPath, feedViewFromParams, inFeedOrder } from './feed';
import type { HarnessSummary } from './types';

describe('feed requests', () => {
  it('leaves defaults out, so an older backend reads the request as before', () => {
    expect(feedPath({ query: '', category: '', sort: 'newest' })).toBe('harnesses?');
    expect(feedPath({ mine: true, query: 'orbit', category: 'Games', sort: 'popular' }, 'next')).toBe('harnesses?mine=true&q=orbit&category=Games&sort=popular&cursor=next');
    expect(feedPath({ forkedFrom: 'starter-orbit' })).toBe('harnesses?forkedFrom=starter-orbit');
  });
  it('reads a shared address, dropping what the Hub does not offer', async () => {
    expect(await feedViewFromParams(Promise.resolve({ q: `  ${'a'.repeat(90)} `, category: 'Games', sort: 'popular' }))).toEqual({ query: 'a'.repeat(80), category: 'Games', sort: 'popular' });
    expect(await feedViewFromParams(Promise.resolve({ q: ['a', 'b'], category: 'Spam', sort: 'oldest' }))).toEqual({ query: '', category: '', sort: 'newest' });
  });
  it('draws a ranked feed in the order the server gave, skipping what is not on offer here', () => {
    const card = (id: string) => ({ id }) as HarnessSummary;
    expect(inFeedOrder(['starter-a', 'post', 'starter-gone', 'starter-b'], [card('post'), card('starter-b'), card('starter-a')]).map(item => item.id))
      .toEqual(['starter-a', 'post', 'starter-b']);
  });
});
