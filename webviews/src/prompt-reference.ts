import { callDiffComments } from "./comments/bridge";

/**
 * Hands a file and line range to the workspace's agent prompt. The native
 * side writes `path:line` (or `path:start-end`) into the focused terminal's
 * input, or into the TextBox when that is showing, so the question about
 * those lines is asked there rather than in a separate comment box.
 */
export function insertLineReferenceIntoPrompt(
  repoRoot: string,
  filePath: string,
  startLine: number,
  endLine: number,
): Promise<boolean> {
  return callDiffComments<{ inserted?: boolean }>("prompt.insertLineReference", {
    repoRoot,
    filePath,
    startLine: Math.min(startLine, endLine),
    endLine: Math.max(startLine, endLine),
  }).then((value) => value?.inserted === true);
}
