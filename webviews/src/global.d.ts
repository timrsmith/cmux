import type { DiffResponse } from "./diff/generated/protocol";

export {};

type AgentSessionNativeReply =
  | { ok: true; value: unknown }
  | { ok: false; error?: { code?: string; userMessage?: string } };

declare global {
  /// Opaque sanitizer policy built by `Resources/markdown-viewer/markdown-sanitizer.js`.
  type CmuxMarkdownSanitizerProfile = { readonly __cmuxMarkdownSanitizerProfile?: never };

  type CmuxMarkdownSanitizerURLContext = {
    namespace: string;
    tag: string;
    name: string;
    value: string;
  };

  var CmuxMarkdownSanitizer: {
    markdownProfile(options?: {
      removeElements?: string[];
      extraAttributes?: Record<string, string[]>;
      url?: (context: CmuxMarkdownSanitizerURLContext) => string | null;
      element?: (source: Element, clean: Element) => boolean;
    }): CmuxMarkdownSanitizerProfile;
    diagramProfile(): CmuxMarkdownSanitizerProfile;
    sanitizeToFragment(
      html: string,
      options: { document: Document; profile: CmuxMarkdownSanitizerProfile },
    ): DocumentFragment;
    serializeFragment(fragment: DocumentFragment, targetDocument: Document): string;
    sanitizeCSS(text: string): string | null;
  };

  var CmuxViewerNavigation: {
    install(options: {
      target: Document | HTMLElement;
      getScroller: () => HTMLElement;
      shortcuts: Record<string, unknown>;
    }): () => void;
    installManualInputReset(options: {
      target: Document | HTMLElement;
      getScroller: () => HTMLElement;
    }): () => void;
    performAction(action: string, scroller: HTMLElement): boolean;
    resetSmoothTarget(scroller: HTMLElement): void;
  };

  interface Window {
    __cmuxPerformDiffViewerNavigationAction?: (action: string) => boolean;
    /**
     * Host entry points, called through evaluateJavaScript. `refresh()`
     * reopens the working-tree session in place (scroll, per-file folds, and
     * the shown repository status stay); `false` means the host should fall
     * back to a full reload.
     */
    cmuxDiffViewer?: {
      refresh(): boolean;
    };
    __cmuxDiffViewer?: {
      codeView?: unknown;
      codeViewItems?: unknown[];
      items?: unknown[];
      state?: unknown;
      streamMetrics?: unknown;
      workerPool?: unknown;
    };
    webkit?: {
      messageHandlers?: {
        agentSession?: {
          postMessage(message: unknown): Promise<AgentSessionNativeReply>;
        };
        cmuxDiff?: {
          postMessage(message: unknown): Promise<DiffResponse>;
        };
      };
    };
  }
}
