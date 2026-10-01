import assert from "node:assert/strict";
import { it } from "node:test";
import { decodePublicShare, staticLinkParts } from "../src/sharing/static.ts";
const id = "11111111-1111-4111-8111-111111111111";
const block = {id, command:"echo hello", state:"sealed", lines:[{text:"<script>alert(1)</script> 😀",spans:[]}]};
it("decodes an immutable public block array as literal text", () => {
  const share = decodePublicShare(id, {schema_version:1,blocks:[block]});
  assert.equal(share.blocks[0]?.lines[0]?.text, block.lines[0]?.text);
});
it("refuses running blocks, controls and unsupported style indices", () => {
  for (const changed of [ {...block,state:"running"}, {...block,lines:[{text:"\x1b]52;secret",spans:[]}]},
    {...block,lines:[{text:"abc",spans:[{start:0,length:3,style:1}]}]} ]) {
    assert.throws(() => decodePublicShare(id,{schema_version:1,blocks:[changed]}));
  }
});
it("only takes the read capability from the fragment", () => {
  const secret = "A".repeat(43);
  assert.deepEqual(staticLinkParts(new URL(`https://site.test/s/?id=${id}#${secret}`)), {locator:id,secret});
  assert.equal(staticLinkParts(new URL(`https://site.test/s/?id=${id}&secret=${secret}`)), null);
});
