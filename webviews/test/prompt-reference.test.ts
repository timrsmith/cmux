import { afterEach, beforeEach, expect, test } from "bun:test";
import { insertLineReferenceIntoPrompt } from "../src/prompt-reference";
import { createDom, installDomGlobals, rejectFetch, resetDom } from "./support/dom";

const requests: any[] = [];
let reply: any = { ok: true, value: { inserted: true } };

beforeEach(() => {
  const dom = createDom("cmux-diff-viewer://0123456789abcdef/unstaged.html");
  installDomGlobals(dom, rejectFetch);
  (dom.window as any).webkit = {
    messageHandlers: {
      cmuxDiffComments: {
        async postMessage(request: any) {
          requests.push(request);
          return reply;
        },
      },
    },
  };
});

afterEach(async () => {
  requests.length = 0;
  reply = { ok: true, value: { inserted: true } };
  await resetDom();
});

test("a gutter line hands path and line range to the native prompt writer", async () => {
  await expect(insertLineReferenceIntoPrompt("/tmp/repo", "libs/a.jsonl", 4, 4)).resolves.toBe(true);
  expect(requests).toHaveLength(1);
  expect(requests[0].method).toBe("prompt.insertLineReference");
  expect(requests[0].params).toEqual({ repoRoot: "/tmp/repo", filePath: "libs/a.jsonl", startLine: 4, endLine: 4 });
});

test("a range dragged upwards is sent in order", async () => {
  await insertLineReferenceIntoPrompt("/tmp/repo", "libs/a.jsonl", 9, 4);
  expect(requests[0].params.startLine).toBe(4);
  expect(requests[0].params.endLine).toBe(9);
});

test("the caller learns when nothing was inserted", async () => {
  reply = { ok: true, value: { inserted: false } };
  await expect(insertLineReferenceIntoPrompt("/tmp/repo", "libs/a.jsonl", 1, 1)).resolves.toBe(false);
  reply = { ok: false, error: { code: "invalid_request", userMessage: "no workspace" } };
  await expect(insertLineReferenceIntoPrompt("/tmp/repo", "libs/a.jsonl", 1, 1)).rejects.toThrow("no workspace");
});
