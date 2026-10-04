'use strict';
require('dotenv').config({ path: '/opt/muffin/.env' });
const { Client, GatewayIntentBits, Partials, EmbedBuilder, AttachmentBuilder, MessageFlags } = require('discord.js');
require('dotenv').config({ path: '/opt/muffin/dm-agent.env', quiet: true });   // Death Muffin dev agent (adapter in ./dm-agent.js)
const { attach: attachDmAgent } = require('./dm-agent');

const GATEWAY_URL = `http://127.0.0.1:${process.env.MUFFIN_GATEWAY_PORT || 4300}`;
const GATEWAY_TOKEN = process.env.MUFFIN_GATEWAY_TOKEN;

async function gatewayGet(path) {
  const res = await fetch(`${GATEWAY_URL}${path}`, {
    headers: { 'x-muffin-gateway-token': GATEWAY_TOKEN },
  });
  const body = await res.json();
  if (!res.ok) throw new Error(body.error || `gateway returned ${res.status}`);
  return body;
}

const STATE_EMOJI = { active: '\u{1F7E2}', inactive: '\u{26AA}', failed: '\u{1F534}', activating: '\u{1F7E1}', deactivating: '\u{1F7E1}' };

function stateEmoji(state) {
  return STATE_EMOJI[state] || '❓';
}

async function handleStatus(interaction) {
  const group = interaction.options.getString('group');
  const data = await gatewayGet(`/v1/registry/list${group ? `?group=${encodeURIComponent(group)}` : ''}`);
  const embed = new EmbedBuilder()
    .setTitle(group ? `Muffin Core — ${group}` : 'Muffin Core — all assets')
    .setColor(0x8a5cf6)
    .setTimestamp(new Date());

  const lines = data.assets.map((a) => {
    const state = a.latest.active_state;
    const marker = state ? stateEmoji(state) : '⚪';
    const restarts = a.latest.n_restarts ? ` (${a.latest.n_restarts} restarts)` : '';
    const crit = a.critical ? ' ❗' : '';
    return `${marker} **${a.id}**${crit} — ${state || 'no unit'}${restarts}`;
  });

  // Discord embed field values cap at 1024 chars — chunk if needed.
  const chunks = [];
  let current = '';
  for (const line of lines) {
    if ((current + '\n' + line).length > 1000) {
      chunks.push(current);
      current = line;
    } else {
      current = current ? `${current}\n${line}` : line;
    }
  }
  if (current) chunks.push(current);
  chunks.forEach((chunk, i) => embed.addFields({ name: i === 0 ? 'Assets' : '​', value: chunk }));

  await interaction.editReply({ embeds: [embed] });
}

async function handleWhatIs(interaction) {
  const assetId = interaction.options.getString('asset');
  const data = await gatewayGet(`/v1/registry/get?asset=${encodeURIComponent(assetId)}`);
  const { asset, latest, recent_events, incidents, baseline_available } = data;

  const embed = new EmbedBuilder()
    .setTitle(asset.name)
    .setColor(asset.critical ? 0xef4444 : 0x8a5cf6)
    .setDescription(asset.notes || '_no notes_')
    .addFields(
      { name: 'ID', value: asset.id, inline: true },
      { name: 'Kind', value: asset.kind, inline: true },
      { name: 'Group', value: asset.asset_group, inline: true },
      { name: 'Critical', value: asset.critical ? 'yes' : 'no', inline: true },
      { name: 'Unit', value: asset.systemd_unit || '_none_', inline: true },
      { name: 'Ports', value: (asset.ports || []).join(', ') || '_none_', inline: true },
      { name: 'Current state', value: latest.active_state ? `${latest.active_state} / ${latest.sub_state}` : '_no data yet_' },
      { name: 'Recent events', value: recent_events.length ? recent_events.map((e) => `[${e.severity}] ${e.kind} @ ${new Date(e.ts).toISOString()}`).join('\n') : '_none_' },
      { name: 'Incidents', value: incidents.length ? String(incidents.length) : '_none_' },
      { name: 'Baseline data', value: baseline_available ? 'available' : 'not enough history yet (needs 14 days)' },
    )
    .setTimestamp(new Date());

  if (asset.restart_runbook) embed.addFields({ name: 'Runbook', value: asset.restart_runbook });

  await interaction.editReply({ embeds: [embed] });
}

async function handleLogs(interaction) {
  const assetId = interaction.options.getString('asset');
  const lines = interaction.options.getInteger('lines');
  const pattern = interaction.options.getString('pattern');
  const params = new URLSearchParams({ asset: assetId });
  if (lines) params.set('lines', String(lines));
  if (pattern) params.set('pattern', pattern);

  const data = await gatewayGet(`/v1/logs?${params.toString()}`);

  if (data.isAttachment) {
    const attachment = new AttachmentBuilder(Buffer.from(data.text, 'utf8'), { name: `${assetId}.log.txt` });
    await interaction.editReply({ content: `Logs for \`${data.unit}\` (redacted):`, files: [attachment] });
  } else {
    await interaction.editReply({ content: `Logs for \`${data.unit}\` (redacted):\n\`\`\`\n${data.text || '(no output)'}\n\`\`\`` });
  }
}

const HANDLERS = { status: handleStatus, 'what-is': handleWhatIs, logs: handleLogs };

async function main() {
  if (!process.env.DISCORD_BOT_TOKEN) {
    console.error('DISCORD_BOT_TOKEN is not set.');
    process.exit(1);
  }

  const client = new Client({
    // GuildMessages + MessageContent: read @mentions in the Death Muffin channel; GuildMessageReactions: the ✅/❌ on proposals.
    intents: [GatewayIntentBits.Guilds, GatewayIntentBits.GuildMessages, GatewayIntentBits.GuildMessageReactions, GatewayIntentBits.MessageContent],
    partials: [Partials.Message, Partials.Channel, Partials.Reaction],
  });
  attachDmAgent(client);

  client.once('clientReady', () => {
    console.log(`Muffin Core Discord bot logged in as ${client.user.tag}`);
  });

  client.on('interactionCreate', async (interaction) => {
    if (!interaction.isChatInputCommand()) return;
    const handler = HANDLERS[interaction.commandName];
    if (!handler) return;

    const ephemeral = interaction.commandName === 'logs';
    try {
      await interaction.deferReply(ephemeral ? { flags: MessageFlags.Ephemeral } : undefined);
      await handler(interaction);
    } catch (err) {
      console.error(`[bot] /${interaction.commandName} failed:`, err);
      const message = `Error: ${err.message}`.slice(0, 1900);
      if (interaction.deferred) await interaction.editReply({ content: message });
    }
  });

  await client.login(process.env.DISCORD_BOT_TOKEN);
}

main().catch((err) => {
  console.error(err);
  process.exit(1);
});
