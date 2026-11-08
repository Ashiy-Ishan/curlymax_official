// Fixed provider origin/endpoints only. No request-provided URL is fetched.
type Item = Record<string, any>;
export function channelLogo(snippet: Item | undefined): string | null {
  for (const size of ['high', 'medium', 'default']) {
    const value = snippet?.thumbnails?.[size]?.url;
    if (typeof value !== 'string' || value.length > 2048) continue;
    try {
      const url = new URL(value);
      if (url.protocol === 'https:' && !url.username && !url.password && !url.port && !url.hash &&
          ['yt3.ggpht.com', 'yt3.googleusercontent.com', 'i.ytimg.com'].includes(url.hostname)) return url.href;
    } catch { /* Try the next thumbnail size. */ }
  }
  return null;
}
export async function fetchCatalog(apiKey: string, channelId: string | null, handle: string, fetcher: typeof fetch = fetch, deadline = Date.now() + 100_000) {
  let requests = 0;
  async function get(resource: 'channels' | 'playlistItems' | 'videos' | 'playlists', params: Record<string, string>) {
    if (++requests > 100 || Date.now() > deadline) throw new Error('YouTube request budget exceeded');
    const query = new URLSearchParams({ ...params, key: apiKey });
    let response: Response;
    try { response = await fetcher(`https://www.googleapis.com/youtube/v3/${resource}?${query}`, { signal: AbortSignal.timeout(12_000), redirect: 'error' }); }
    catch { throw new Error('YouTube temporarily unavailable'); }
    if (!response.ok) throw new Error(response.status === 403 || response.status === 401 ? 'YouTube quota or access denied' : 'YouTube temporarily unavailable');
    let body: Item;
    try { body = await response.json(); } catch { throw new Error('YouTube response invalid'); }
    if (!Array.isArray(body.items)) throw new Error('YouTube response invalid');
    return body;
  }
  async function pages(resource: 'playlistItems' | 'playlists', params: Record<string, string>, max: number) {
    const items: Item[] = [];
    let pageToken: string | undefined;
    do {
      const page = await get(resource, { ...params, maxResults: '50', ...(pageToken ? { pageToken } : {}) });
      items.push(...page.items);
      if (items.length > max || (items.length >= max && page.nextPageToken)) throw new Error('YouTube catalog exceeds supported import size');
      pageToken = page.nextPageToken;
    } while (pageToken);
    return items;
  }
  const channels = await get('channels', { part: 'snippet,contentDetails', ...(channelId ? { id: channelId } : { forHandle: handle }) });
  const channel = channels.items[0];
  if (!channel || !/^UC[A-Za-z0-9_-]{22}$/.test(channel.id) || !channel.contentDetails?.relatedPlaylists?.uploads) throw new Error('YouTube channel not found');
  const uploads = await pages('playlistItems', { part: 'contentDetails', playlistId: channel.contentDetails.relatedPlaylists.uploads }, 1000);
  const ids = [...new Set<string>(uploads.map((v) => v.contentDetails?.videoId).filter((id) => typeof id === 'string' && /^[A-Za-z0-9_-]{11}$/.test(id)))];
  const videos: Item[] = [];
  const count = (value: unknown) => typeof value === 'string' && /^\d{1,18}$/.test(value) ? value : null;
  const thumbnail = (snippet: Item) => snippet.thumbnails?.high?.url ?? snippet.thumbnails?.medium?.url ?? snippet.thumbnails?.default?.url ?? null;
  for (let i = 0; i < ids.length; i += 50) {
    const batch = await get('videos', { part: 'snippet,statistics,status', id: ids.slice(i, i + 50).join(',') });
    for (const v of batch.items) {
      if (v.status?.privacyStatus !== 'public' || v.snippet?.channelId !== channel.id) continue;
      videos.push({ id: v.id, channel_id: channel.id, title: v.snippet.title, description: v.snippet.description,
        published_at: v.snippet.publishedAt, thumbnail_url: thumbnail(v.snippet),
        view_count: count(v.statistics?.viewCount), like_count: count(v.statistics?.likeCount), comment_count: count(v.statistics?.commentCount) });
    }
  }
  const lists = await pages('playlists', { part: 'snippet,status', channelId: channel.id }, 50);
  const playlists: Item[] = [];
  for (const p of lists) {
    if (p.status?.privacyStatus !== 'public') continue;
    const members = await pages('playlistItems', { part: 'contentDetails', playlistId: p.id }, 1000);
    playlists.push({ id: p.id, title: p.snippet.title, description: p.snippet.description, thumbnail_url: thumbnail(p.snippet), video_ids: members.map((v) => v.contentDetails?.videoId).filter((v) => typeof v === 'string') });
  }
  return { channelId: channel.id as string, channelLogoUrl: channelLogo(channel.snippet), videos, playlists };
}
