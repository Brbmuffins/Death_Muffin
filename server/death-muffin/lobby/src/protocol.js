'use strict';
// Wire protocol (see README.md). Binary frames carry opaque game packets behind an 11-byte header; text frames are JSON control messages.
const HEADER_BYTES = 11;
const KIND_DATA = 1;
const HOST_PEER_ID = 1;
const BROADCAST = 0;

function readHeader(buf) {
  if (buf.length < HEADER_BYTES || buf[0] !== KIND_DATA) return null;
  return { mode: buf[1], channel: buf[2], src: buf.readUInt32LE(3), dst: buf.readUInt32LE(7) };
}

module.exports = { HEADER_BYTES, KIND_DATA, HOST_PEER_ID, BROADCAST, readHeader };
