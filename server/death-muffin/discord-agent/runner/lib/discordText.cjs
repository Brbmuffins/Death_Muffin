'use strict';
// Discord caps a message at 2000 characters. Long agent replies are split into several messages on line boundaries, keeping
// ``` code blocks balanced across the split; a reply too long for a few messages becomes a short preview plus the full text
// as a file attachment.
const MAX = 1900;
const MAX_CHUNKS = 15;   // owner 2026-10-09: forum threads, split into messages; reply.md only for runaway output (~28k+ chars)

function splitForDiscord(text, max = MAX) {
  const chunks = [];
  let cur = ''; let fence = null;                     // fence = opening line of the code block we are inside, e.g. "```js"
  const reserve = () => (fence ? fence.length + 5 : 0); // room for "\n```" now and the reopening fence line next chunk
  const flush = () => {
    if (cur.trim() && cur !== (fence ? fence : '')) chunks.push(cur + (fence ? '\n```' : ''));
    cur = fence || '';
  };
  const add = (line) => {
    if (cur && cur.length + 1 + line.length + reserve() > max) flush();
    cur = cur ? `${cur}\n${line}` : line;
  };
  for (const line of String(text).split('\n')) {
    let rest = line;
    while (rest.length + reserve() > max) {           // one line longer than a message: hard-wrap it
      flush();
      const room = max - reserve() - cur.length - 1;
      add(rest.slice(0, room)); rest = rest.slice(room);
    }
    add(rest);
    if (rest.trim().startsWith('```')) fence = fence ? null : rest.trim();
  }
  flush();
  return chunks;
}

/** { chunks } when it fits in a few messages, otherwise { chunks: [preview], file: { name, text } }. */
function planReply(text, { max = MAX, maxChunks = MAX_CHUNKS } = {}) {
  const t = String(text).trim();
  if (!t) return { chunks: [] };
  const chunks = splitForDiscord(t, max);
  if (chunks.length <= maxChunks) return { chunks };
  const note = '\n\n*(Full reply attached as reply.md: too long for a few Discord messages.)*';
  return { chunks: [splitForDiscord(t, max - note.length)[0] + note], file: { name: 'reply.md', text: t } };
}

module.exports = { splitForDiscord, planReply, MAX, MAX_CHUNKS };
